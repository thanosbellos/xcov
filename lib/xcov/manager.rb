require 'fastlane_core'
require 'pty'
require 'open3'
require 'fileutils'
require 'terminal-table'
require 'xcov-core'
require 'pathname'
require 'json'

module Xcov
  class Manager

    def initialize(options)
      # Set command options
      Xcov.config = options

      # Set project options
      FastlaneCore::Project.detect_projects(options)
      Xcov.project = FastlaneCore::Project.new(options)

      # Set ignored files handler
      Xcov.ignore_handler = IgnoreHandler.new

      # Print summary
      FastlaneCore::PrintTable.print_values(config: options, hide_keys: [:slack_url, :coveralls_repo_token], title: "Summary for xcov #{Xcov::VERSION}")
    end

    def run
      # Run xcov
      json_report = parse_xccoverage
      report = generate_xcov_report(json_report)
      validate_report(report)
      submit_to_coveralls(report)
      tmp_dir = File.join(Xcov.config[:output_directory], 'tmp')
      FileUtils.rm_rf(tmp_dir) if File.directory?(tmp_dir)
    end

    def parse_xccoverage
      # Find .xccoverage file
      extension = Xcov.config[:legacy_support] ? "xccoverage" : "xccovreport"
      test_logs_path = derived_data_path + "Logs/Test/"
      xccoverage_files = Dir["#{test_logs_path}*.#{extension}", "#{test_logs_path}*.xcresult/*/action.#{extension}"].sort_by { |filename| File.mtime(filename) }.reverse

      unless test_logs_path.directory? && !xccoverage_files.empty?
        ErrorHandler.handle_error("XccoverageFileNotFound")
      end

      # Convert .xccoverage file to json
      ide_foundation_path = Xcov.config[:legacy_support] ? nil : Xcov.config[:ideFoundationPath]
      json_report = Xcov::Core::Parser.parse(xccoverage_files.first, Xcov.config[:output_directory], ide_foundation_path)
      ErrorHandler.handle_error("UnableToParseXccoverageFile") if json_report.nil?

      json_report
    end

    private

    def generate_xcov_report(json_report)
      # Create output path
      output_path = Xcov.config[:output_directory]
      FileUtils.mkdir_p(output_path)

      # Convert report to xcov model objects
      report = Report.map(json_report)

      # Raise exception in case of failure
      ErrorHandler.handle_error("UnableToMapJsonToXcovModel") if report.nil?

      if Xcov.config[:html_report] then
        resources_path = File.join(output_path, "resources")
        FileUtils.mkdir_p(resources_path)

        # Copy images to output resources folder
        Dir[File.join(File.dirname(__FILE__), "../../assets/images/*")].each do |path|
          FileUtils.cp_r(path, resources_path)
        end

        # Copy stylesheets to output resources folder
        Dir[File.join(File.dirname(__FILE__), "../../assets/stylesheets/*")].each do |path|
          FileUtils.cp_r(path, resources_path)
        end

        # Copy javascripts to output resources folder
        Dir[File.join(File.dirname(__FILE__), "../../assets/javascripts/*")].each do |path|
          FileUtils.cp_r(path, resources_path)
        end

        # Create HTML report
        File.open(File.join(output_path, "index.html"), "wb") do |file|
          file.puts report.html_value
        end
      end

      # Create Markdown report
      if Xcov.config[:markdown_report] then
        File.open(File.join(output_path, "report.md"), "wb") do |file|
          file.puts report.markdown_value
        end
      end

      # Create JSON report
      if Xcov.config[:json_report] then
        File.open(File.join(output_path, "report.json"), "wb") do |file|
          file.puts report.json_value.to_json
        end
      end

      # Post result
      SlackPoster.new.run(report)

      # Print output
      table_rows = []
      report.targets.each do |target|
        table_rows << [target.name, target.displayable_coverage]
      end
      puts Terminal::Table.new({
        title: "xcov Coverage Report".green,
        rows: table_rows
      })
      puts ""

      report
    end

    def validate_report(report)
      # Raise exception if overall coverage is under threshold
      minimumPercentage = Xcov.config[:minimum_coverage_percentage] / 100
      if minimumPercentage > report.coverage
        error_message = "Actual Code Coverage (#{"%.2f%" % (report.coverage*100)}) below threshold of #{"%.2f%" % (minimumPercentage*100)}"
        ErrorHandler.handle_error_with_custom_message("CoverageUnderThreshold", error_message)
      end
    end

    def submit_to_coveralls(report)
      if Xcov.config[:disable_coveralls]
        return
      end
      if !Xcov.config[:coveralls_repo_token].nil? || !(Xcov.config[:coveralls_service_name].nil? && Xcov.config[:coveralls_service_job_id].nil?)
        CoverallsHandler.submit(report)
      end
    end

    # Auxiliar methods

    def derived_data_path
      # If DerivedData path was supplied, return
      return Pathname.new(Xcov.config[:derived_data_path]) unless Xcov.config[:derived_data_path].nil?

      # Otherwise check project file
      product_builds_path = Pathname.new(Xcov.project.default_build_settings(key: "SYMROOT"))
      return product_builds_path.parent.parent
    end

  end
end
