public import Foundation
import Darwin

/// One child process for ``AsyncProcess`` to run: what to start, what to feed it and how long it may take.
public struct ProcessRequest: Sendable {
    /// Where the child's standard error goes.
    public enum ErrorOutput: Sendable {
        /// `/dev/null`.
        case discard
        /// Into ``ProcessOutcome/output``, interleaved with standard output (one pipe, so a noisy child
        /// cannot fill a second pipe nobody drains).
        case merge
        /// Into ``ProcessOutcome/errorOutput``.
        case separate
    }

    /// The program to run.
    public var executable: URL
    /// Its arguments, without the program name.
    public var arguments: [String]
    /// Its whole environment; nil inherits this process's.
    public var environment: [String: String]?
    /// Its working directory; nil inherits this process's.
    public var directory: URL?
    /// Bytes written to its standard input, which then closes; nil gives it `/dev/null`.
    public var input: Data?
    /// Where its standard error goes.
    public var errorOutput: ErrorOutput
    /// How long it may run before it gets SIGTERM and ``AsyncProcess/run(_:)`` throws
    /// ``ProcessFailure/timedOut``; nil waits for its exit.
    public var timeout: Duration?
    /// The signal a timeout or a cancel sends: `SIGTERM` lets the child clean up (git removes its lock
    /// files); `SIGKILL` for a child that may ignore `SIGTERM`.
    public var stopSignal: Int32

    /// Describes one run.
    ///
    /// - Parameters:
    ///   - executable: the program to run.
    ///   - arguments: its arguments.
    ///   - environment: its whole environment; nil (the default) inherits this process's.
    ///   - directory: its working directory; nil (the default) inherits this process's.
    ///   - input: bytes for its standard input; nil (the default) gives it `/dev/null`.
    ///   - errorOutput: where its standard error goes; default ``ErrorOutput/discard``.
    ///   - timeout: how long it may run; nil (the default) waits for its exit.
    ///   - stopSignal: what a timeout or a cancel sends; default `SIGTERM`.
    public init(_ executable: URL, _ arguments: [String] = [], environment: [String: String]? = nil,
                directory: URL? = nil, input: Data? = nil, errorOutput: ErrorOutput = .discard,
                timeout: Duration? = nil, stopSignal: Int32 = SIGTERM) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.input = input
        self.errorOutput = errorOutput
        self.timeout = timeout
        self.stopSignal = stopSignal
    }
}
