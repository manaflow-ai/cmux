internal import Foundation

/// Production runner backed by `Process`.
///
/// Each call owns its process and pipes, drains stdout off the caller's actor,
/// and applies a deadline so wedged system tools do not hang a mobile RPC
/// indefinitely.
public struct SystemMacPowerCommandRunner: MacPowerCommandRunning {
    private let timeout: TimeInterval?

    /// Creates a system command runner.
    /// - Parameter timeout: Per-command deadline in seconds. Pass `nil` only for
    ///   tests that intentionally need to observe an unbounded command.
    public init(timeout: TimeInterval? = 10) {
        self.timeout = timeout
    }

    /// Runs a command and returns whether it exited with status 0.
    @discardableResult
    public func run(_ tool: String, _ arguments: [String]) async -> Bool {
        await MacPowerProcessLauncher().run(tool, arguments, captureOutput: false, timeout: timeout).success
    }

    /// Runs a command and captures stdout when it exits with status 0.
    public func capture(_ tool: String, _ arguments: [String]) async -> String? {
        let result = await MacPowerProcessLauncher().run(tool, arguments, captureOutput: true, timeout: timeout)
        return result.success ? result.output : nil
    }
}
