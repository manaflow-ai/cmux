/// The outcome of running an external command via ``CommandRunning``.
///
/// All fields are optional because a command can fail to launch, time out, or be
/// killed before producing output. Inspect ``executionError`` first (the process
/// never started), then ``timedOut`` (it was terminated for exceeding its
/// deadline), then ``exitStatus`` and the captured streams.
///
/// ```swift
/// let result = await runner.run(directory: ".", executable: "gh", arguments: ["auth", "token"], timeout: 5)
/// if result.executionError == nil, !result.timedOut, result.exitStatus == 0 {
///     print(result.stdout ?? "")
/// }
/// ```
public struct CommandResult: Sendable, Equatable {
    /// Captured standard output decoded as UTF-8, or `nil` when unavailable.
    public let stdout: String?
    /// Captured standard error decoded as UTF-8, or `nil` when unavailable.
    public let stderr: String?
    /// The process exit status, or `nil` when the process did not exit normally
    /// (it timed out or never launched).
    public let exitStatus: Int32?
    /// Whether the process was terminated for exceeding its timeout.
    public let timedOut: Bool
    /// Whether stdout or stderr exceeded the caller's capture limit.
    public let outputLimitExceeded: Bool
    /// Whether cancellation confirmed that the spawned process tree exited.
    ///
    /// `nil` means the command did not complete through the cancellation path.
    public let cancellationCleanupSucceeded: Bool?
    /// A description of the launch failure when the process never started, else `nil`.
    public let executionError: String?

    /// Creates a command result.
    /// - Parameters:
    ///   - stdout: UTF-8 standard output, or `nil`.
    ///   - stderr: UTF-8 standard error, or `nil`.
    ///   - exitStatus: The process exit status, or `nil` if it did not exit normally.
    ///   - timedOut: Whether the process was killed for exceeding its deadline.
    ///   - outputLimitExceeded: Whether a captured stream exceeded its byte limit.
    ///   - cancellationCleanupSucceeded: Whether cancellation confirmed process-tree exit, or `nil` otherwise.
    ///   - executionError: A launch-failure description, or `nil`.
    public init(
        stdout: String?,
        stderr: String?,
        exitStatus: Int32?,
        timedOut: Bool,
        outputLimitExceeded: Bool = false,
        cancellationCleanupSucceeded: Bool? = nil,
        executionError: String?
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
        self.timedOut = timedOut
        self.outputLimitExceeded = outputLimitExceeded
        self.cancellationCleanupSucceeded = cancellationCleanupSucceeded
        self.executionError = executionError
    }
}
