public import Foundation
import Darwin

/// One child process for ``AsyncProcess`` to run: what to start, what to feed it and how long it may take.
public struct ProcessRequest: Sendable {
    /// Which processes a stop signal reaches.
    public enum TerminationScope: Sendable, Equatable {
        /// Signal only the requested child process.
        case process
        /// Signal the child and every descendant in its dedicated process group.
        case processGroup
    }

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

    /// What a cancel of the awaiting task does to the child, and when a stop returns.
    public enum CancelBehavior: Sendable {
        /// The cancel stops the child (the stop signal, then SIGKILL after ``ProcessRequest/killGrace``), and
        /// a stop (cancel or timeout) returns at once. For reads: nobody wants the answer any more.
        case stop
        /// The child runs to its exit or its timeout whatever the caller does, and a timeout returns once
        /// the child has exited (at most ``ProcessRequest/killGrace`` after the stop signal, when it gets
        /// SIGKILL). For writes and write sequences: a page reload that cancels its request must not stop
        /// `git restore` half way, or start the next step while git still holds `index.lock`.
        case finish
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
    /// How long it may run before it gets the stop signal and ``AsyncProcess/run(_:)`` throws
    /// ``ProcessFailure/timedOut``; nil waits for its exit.
    public var timeout: Duration?
    /// The signal a timeout or a cancel sends first: `SIGTERM` lets the child clean up (git removes its
    /// lock files); a child still running ``killGrace`` later gets `SIGKILL`.
    public var stopSignal: Int32
    /// What a cancel of the awaiting task does; default ``CancelBehavior/stop``.
    public var onCancel: CancelBehavior
    /// How long a stopped child has to exit after the stop signal before it gets SIGKILL, so a child that
    /// ignores or traps `SIGTERM` (a hook, a hung credential helper) always ends. Default 2 s: the grace
    /// the Changes view's git runs had for removing `index.lock` before AsyncProcess.
    public var killGrace: Duration
    /// Whether timeout and cancellation signals target only the child or its dedicated process group.
    public var terminationScope: TerminationScope
    /// Called with the child's pid right after it started, on the thread that started it, before any
    /// stop can reach it (diagnostics; tests watch the child's exit with it).
    public var onLaunch: (@Sendable (Int32) -> Void)?

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
    ///   - onCancel: what a cancel of the awaiting task does; default ``CancelBehavior/stop``.
    ///   - killGrace: how long a stopped child has before SIGKILL; default 2 s.
    ///   - terminationScope: whether stops signal only the child or its process group; default `.process`.
    ///   - onLaunch: called with the child's pid right after it started; default none.
    public init(_ executable: URL, _ arguments: [String] = [], environment: [String: String]? = nil,
                directory: URL? = nil, input: Data? = nil, errorOutput: ErrorOutput = .discard,
                timeout: Duration? = nil, stopSignal: Int32 = SIGTERM, onCancel: CancelBehavior = .stop,
                killGrace: Duration = .seconds(2), terminationScope: TerminationScope = .process,
                onLaunch: (@Sendable (Int32) -> Void)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.input = input
        self.errorOutput = errorOutput
        self.timeout = timeout
        self.stopSignal = stopSignal
        self.onCancel = onCancel
        self.killGrace = killGrace
        self.terminationScope = terminationScope
        self.onLaunch = onLaunch
    }
}
