public import Foundation
import CmuxNextCompat
import Darwin
import Dispatch

/// Runs a child process and awaits its end without blocking any thread.
///
/// `run(_:)` may be called from any actor, the main actor included: the caller only registers the run;
/// the spawn, the reads and the exit all happen on the run's own serial queue.
///
/// `process.waitUntilExit()` and `readDataToEndOfFile()` park a thread until the child ends; inside a
/// `Task` that thread is one of the cooperative pool's (one per core), so a few slow `git` or `gh` runs
/// stall every task in the app. Here nothing waits: the child's output arrives through read sources on
/// one serial queue, its exit through `terminationHandler`, and the caller's continuation resumes on
/// the first of exit, timeout and cancellation. Output the child wrote before it exited is all read
/// (the exit drains the pipes); a grandchild that keeps the pipe open does not hold the result.
///
/// ```swift
/// let outcome = try await processes.run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/git"),
///                                                      ["-C", folder, "status", "--porcelain"],
///                                                      timeout: .seconds(5)))
/// guard outcome.succeeded else { return nil }
/// ```
public struct AsyncProcess: Sendable {
    private let clock: any Clock<Duration>
    private let launch: @Sendable (Process) throws -> Void

    /// Creates a runner.
    ///
    /// - Parameters:
    ///   - clock: the clock of the request's timeout; tests pass a manual one.
    ///   - launch: starts the configured child (`Process.run()`, a fork and exec); tests pass one that
    ///     records where it ran and then starts it.
    public init(clock: any Clock<Duration> = ContinuousClock(),
                launch: @escaping @Sendable (Process) throws -> Void = { try $0.run() }) {
        self.clock = clock
        self.launch = launch
    }

    /// Starts the request's child and returns when it has exited.
    ///
    /// - Parameter request: what to run.
    /// - Returns: its exit status and output.
    /// - Throws: ``ProcessFailure/launch(_:)`` when it could not start, ``ProcessFailure/timedOut`` past
    ///   the request's timeout, `CancellationError` when the caller is cancelled (the child gets the
    ///   request's stop signal in both cases).
    public func run(_ request: ProcessRequest) async throws -> ProcessOutcome {
        try Task.checkCancellation()
        let run = ProcessRun(request, launch: launch)
        let deadline = request.timeout.map { _ in DemandTimer(owner: "process.\(request.executable.lastPathComponent)", clock: clock) }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(continuation)
                if let deadline, let timeout = request.timeout {
                    deadline.schedule(after: timeout) { run.stop(ProcessFailure.timedOut) }
                }
            }
        } onCancel: {
            run.stop(CancellationError())
        }
    }
}
