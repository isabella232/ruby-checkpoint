require "cgi"
require "json"
require "net/http"
require "securerandom"
require "uri/http"

require "checkpoint/platform"
require "checkpoint/version"

module Checkpoint
  @@disabled = false

  # Checks for the latest version information as well as alerts.
  #
  # @param [Hash] opts the options to check with
  # @option opts [String] :product The product
  # @option opts [String] :version The version of the product
  # @option opts [String] :arch The arch this is running on. If not specified,
  #   we will try to determine it.
  # @option opts [String] :os The OS this is running on. If not specified,
  #   we will try to determine it.
  # @option opts [String] :signature A signature to eliminate duplicates
  # @option opts [String] :signature_file If specified, a signature will
  #   be read from this path. If it doesn't exist, it will be created with
  #   a new random signature.
  # @option opts [String] :cache_file If specified, the response will be
  #   cached here for cache_time period (defaults to 48 hours).
  def self.check(**opts)
    return nil if @@disabled

    # If we have the cache file, then just return the contents.
    if opts[:cache_file] && File.file?(opts[:cache_file])
      # If the cache file is too old, then delete it
      mtime = File.mtime(opts[:cache_file]).to_i
      limit = Time.now.to_i - (60 * 60 * 24 * 2)
      if mtime > limit
        return build_check(File.read(opts[:cache_file]))
      end

      # Delete the file
      File.unlink(opts[:cache_file])
    end

    # Build the query parameters
    query = {
      version: opts[:version],
      arch: opts[:arch],
      os: opts[:os],
      signature: opts[:signature],
    }
    query[:arch] ||= Platform.arch
    query[:os] ||= Platform.os

    # If a signature file was specified, read it from there.
    if opts[:signature_file]
      if !File.file?(opts[:signature_file])
        File.open(opts[:signature_file], "w+") do |f|
          f.write(SecureRandom.uuid.to_s + "\n")
        end
      end

      query[:signature] = File.read(opts[:signature_file]).chomp
    end

    # Turn the raw query parameters into a proper query string
    query = query.map do |k, v|
      if v
        [CGI.escape(k.to_s), "=", CGI.escape(v.to_s)].join
      end
    end.compact.join("&")

    # Build the URL
    uri = URI::HTTP.build(
      host: "api.checkpoint.hashicorp.com",
      path: "/v1/check/#{opts[:product]}",
      query: query,
    )

    headers = {
      "Accept" => "application/json",
      "User-Agent" => "HashiCorp/ruby-checkpoint #{VERSION}",
    }
    http = Net::HTTP.new(uri.host, uri.port)
    resp = http.get(uri.path, headers)
    if !resp.is_a?(Net::HTTPSuccess)
      return nil
    end

    # If we have a cache file, write it
    if opts[:cache_file]
      File.open(opts[:cache_file], "w+") do |f|
        f.write(resp.body)
      end
    end

    build_check(resp.body)
  rescue Exception
    # We don't want check to fail for any reason, so just return nil
    return nil
  end

  # Disables checkpoint.
  def self.disable!
    @@disabled = true
  end

  protected

  def self.build_check(response)
    JSON.parse(response).tap do |result|
      result["outdated"] = !!result["outdated"]
    end
  end
end
