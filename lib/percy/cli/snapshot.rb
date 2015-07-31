require 'find'
require 'digest'
require 'uri'
require 'thread/pool'

Thread::Pool.abort_on_exception = true

module Percy
  class Cli
    module Snapshot
      # Static resource types that an HTML file might load and that we want to upload for rendering.
      STATIC_RESOURCE_EXTENSIONS = [
        '.css', '.jpg', '.jpeg', '.gif', '.ico', '.png', '.bmp', '.pict', '.tif', '.tiff', '.ttf',
        '.eot', '.woff', '.otf', '.svg', '.svgz', '.webp', '.ps',
      ].freeze

      DEFAULT_SNAPSHOTS_REGEX = /\.(html|htm)$/

      def run_snapshot(root_dir, options = {})
        repo = options[:repo] || Percy.config.repo
        strip_prefix = File.absolute_path(options[:strip_prefix] || root_dir)
        num_threads = options[:threads] || 10
        snapshot_limit = options[:snapshot_limit]

        # Find all the static files in the given root directory.
        root_paths = find_root_paths(root_dir, snapshots_regex: options[:snapshots_regex])
        resource_paths = find_resource_paths(root_dir)
        root_resources = build_resources(root_paths, strip_prefix, is_root: true)
        related_resources = build_resources(resource_paths, strip_prefix)
        all_resources = root_resources + related_resources

        if root_resources.empty?
          say "No root resource files found. Are there HTML files in the given directory?"
          exit(-1)
        end

        say 'Creating build...'
        build = Percy.create_build(repo, resources: related_resources)

        say 'Uploading build resources...'
        upload_missing_resources(build, build, all_resources, {num_threads: num_threads})

        # Upload a snapshot for every root resource, and associate the related_resources.
        output_lock = Mutex.new
        snapshot_thread_pool = Thread.pool(num_threads)
        total = snapshot_limit ? [root_resources.length, snapshot_limit].min : root_resources.length
        root_resources.each_with_index do |root_resource, i|
          break if snapshot_limit && i + 1 > snapshot_limit
          snapshot_thread_pool.process do
            output_lock.synchronize do
              say "Uploading snapshot (#{i+1}/#{total}): #{root_resource.resource_url}"
            end
            snapshot = Percy.create_snapshot(build['data']['id'], [root_resource])
            upload_missing_resources(build, snapshot, all_resources, {num_threads: num_threads})
            Percy.finalize_snapshot(snapshot['data']['id'])
          end
        end
        snapshot_thread_pool.wait
        snapshot_thread_pool.shutdown

        # Finalize the build.
        say 'Finalizing build...'
        Percy.finalize_build(build['data']['id'])
        say "Done! Percy is now processing, you can view the visual diffs here:"
        say build['data']['attributes']['web-url']
      end

      private

      def find_root_paths(dir_path, options = {})
        snapshots_regex = options[:snapshots_regex] || DEFAULT_SNAPSHOTS_REGEX

        file_paths = []
        Find.find(dir_path).each do |relative_path|
          path = File.absolute_path(relative_path)
          # Skip directories.
          next if !FileTest.file?(path)
          # Skip files that don't match the snapshots_regex.
          next if !path.match(snapshots_regex)
          file_paths << path
        end
        file_paths
      end

      def find_resource_paths(dir_path)
        file_paths = []
        Find.find(dir_path).each do |relative_path|
          path = File.absolute_path(relative_path)

          # Skip directories.
          next if !FileTest.file?(path)
          # Skip dot files.
          next if path.match(/\/\./)
          # Only include files with the above static extensions.
          next if !Percy::Cli::STATIC_RESOURCE_EXTENSIONS.include?(File.extname(path))

          file_paths << path
        end
        file_paths
      end

      def maybe_add_protocol(url)
        url[0..1] == '//' ? "http:#{url}" : url
      end

      def build_resources(paths, strip_prefix, options = {})
        resources = []

        # Strip trailing slash from strip_prefix.
        strip_prefix = strip_prefix[0..-2] if strip_prefix[-1] == '/'

        paths.each do |path|
          sha = Digest::SHA256.hexdigest(File.read(path))
          resource_url = URI.escape(path.sub(strip_prefix, ''))
          resources << Percy::Client::Resource.new(
            resource_url, sha: sha, is_root: options[:is_root], path: path)
        end
        resources
      end

      # Uploads missing resources either for a build or snapshot.
      def upload_missing_resources(build, obj, potential_resources, options = {})
        # Upload the content for any missing resources.
        missing_resources = obj['data']['relationships']['missing-resources']['data']
        bar = Commander::UI::ProgressBar.new(
          missing_resources.length,
          title: 'Uploading resources...',
          format: ':title |:progress_bar| :percent_complete% complete - :resource_url',
          width: 20,
          complete_message: nil,
        )
        output_lock = Mutex.new
        uploader_thread_pool = Thread.pool(options[:num_threads] || 10)
        missing_resources.each do |missing_resource|
          uploader_thread_pool.process do
            missing_resource_sha = missing_resource['id']
            resource = potential_resources.find { |r| r.sha == missing_resource_sha }
            path = resource.resource_url
            output_lock.synchronize do
              bar.increment resource_url: resource.resource_url
            end

            # Remote resources are stored in 'content', local resources are read from the filesystem.
            content = resource.content || File.read("#{resource.path}")

            Percy.upload_resource(build['data']['id'], content)
          end
        end
        uploader_thread_pool.wait
        uploader_thread_pool.shutdown
      end
    end
  end
end
