public import Foundation

/// Captured output and termination status from a hook process.
public struct HookProcessResult: Sendable, Equatable {
    /// Process exit status, or `nil` when no normal exit status is available.
    public let exitStatus: Int32?

    /// Captured standard output.
    public let stdout: Data

    /// Captured standard error, capped by the runner for logging.
    public let stderr: Data

    /// Whether the hook exceeded its deadline.
    public let timedOut: Bool

    /// Process launch failure text, if launch failed.
    public let launchFailure: String?

    /// Creates a hook process result.
    /// - Parameters:
    ///   - exitStatus: Process exit status.
    ///   - stdout: Captured standard output.
    ///   - stderr: Captured standard error.
    ///   - timedOut: Whether the hook exceeded its deadline.
    ///   - launchFailure: Process launch failure text.
    public init(
        exitStatus: Int32?,
        stdout: Data,
        stderr: Data,
        timedOut: Bool,
        launchFailure: String?
    ) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.launchFailure = launchFailure
    }
}
