import CmuxFoundation
import Foundation

/// Owns bounded subprocess admission for restored diff-viewer picker routes.
/// Overload is rejected instead of queued, so stale WebKit requests can never
/// accumulate behind the active commands. Cancelling an admitted caller
/// propagates into ``CommandRunner``, which terminates its child process.
actor DiffViewerPickerCommandRunner {
    private let commandRunner: any CommandRunning
    private let executablePath: String?
    private let timeout: TimeInterval
    private let concurrencyLimit: Int
    private var activeCount = 0

    init() {
        commandRunner = CommandRunner()
        executablePath = Self.bundledCLIPath()
        timeout = 15
        concurrencyLimit = 2
    }

    init(
        commandRunner: any CommandRunning,
        executablePath: String?,
        timeout: TimeInterval = 15,
        concurrencyLimit: Int = 2
    ) {
        self.commandRunner = commandRunner
        self.executablePath = executablePath
        self.timeout = timeout
        self.concurrencyLimit = max(1, concurrencyLimit)
    }

    /// Runs one bundled CLI picker command after acquiring a bounded permit.
    /// Returns standard output only for a successful, uncancelled invocation.
    func run(arguments: [String]) async -> String? {
        guard let executablePath,
              !Task.isCancelled,
              activeCount < concurrencyLimit else {
            return nil
        }
        activeCount += 1
        defer { activeCount -= 1 }

        guard !Task.isCancelled else { return nil }
        let result = await commandRunner.run(
            directory: "/",
            executable: executablePath,
            arguments: arguments,
            timeout: timeout
        )
        guard !Task.isCancelled,
              result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            return nil
        }
        return result.stdout
    }

    private static func bundledCLIPath() -> String? {
        if let environmentPath = ProcessInfo.processInfo.environment["CMUX_BUNDLED_CLI_PATH"],
           !environmentPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: environmentPath) {
            return environmentPath
        }
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
}
