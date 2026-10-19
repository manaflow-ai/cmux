public import CmuxFoundation
public import Foundation
import OSLog

nonisolated private let diffViewerPickerLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "DiffViewerPicker"
)

/// Owns bounded subprocess admission for restored diff-viewer picker routes.
///
/// Overload is rejected instead of queued, so stale WebKit requests cannot
/// accumulate behind active commands. Cancelling an admitted caller propagates
/// into ``CommandRunner``, which terminates its child process.
public actor DiffViewerPickerCommandRunner {
    private let commandRunner: any CommandRunning
    private let executablePath: String?
    private let timeout: TimeInterval
    private let concurrencyLimit: Int
    private var activeCount = 0

    /// Creates a production runner targeting the bundled cmux CLI.
    public init() {
        commandRunner = CommandRunner()
        executablePath = Self.bundledCLIPath()
        timeout = 15
        concurrencyLimit = 2
    }

    /// Creates a runner with injectable command execution and admission limits.
    ///
    /// - Parameters:
    ///   - commandRunner: Command execution capability.
    ///   - executablePath: Absolute bundled CLI path, or `nil` to reject commands.
    ///   - timeout: Per-command deadline in seconds.
    ///   - concurrencyLimit: Maximum simultaneously executing commands.
    public init(
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
    ///
    /// Returns standard output only for a successful, uncancelled invocation.
    /// Every `nil` outcome records a distinct privacy-safe debug reason.
    ///
    /// - Parameter arguments: Arguments passed to the bundled CLI executable.
    /// - Returns: Standard output for a successful invocation, or `nil` after a logged rejection.
    public func run(arguments: [String]) async -> String? {
        guard let executablePath else {
            diffViewerPickerLogger.debug("picker command rejected reason=missing_executable")
            return nil
        }
        guard !Task.isCancelled else {
            diffViewerPickerLogger.debug("picker command rejected reason=pre_command_cancellation")
            return nil
        }
        guard activeCount < concurrencyLimit else {
            diffViewerPickerLogger.debug("picker command rejected reason=capacity")
            return nil
        }

        activeCount += 1
        defer { activeCount -= 1 }
        guard !Task.isCancelled else {
            diffViewerPickerLogger.debug("picker command rejected reason=pre_command_cancellation")
            return nil
        }

        let result = await commandRunner.run(
            directory: "/",
            executable: executablePath,
            arguments: arguments,
            timeout: timeout
        )
        guard !Task.isCancelled else {
            diffViewerPickerLogger.debug("picker command rejected reason=post_command_cancellation")
            return nil
        }
        guard result.executionError == nil else {
            diffViewerPickerLogger.debug("picker command rejected reason=execution_error")
            return nil
        }
        guard !result.timedOut else {
            diffViewerPickerLogger.debug("picker command rejected reason=timeout")
            return nil
        }
        guard result.exitStatus == 0 else {
            diffViewerPickerLogger.debug("picker command rejected reason=nonzero_exit")
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
