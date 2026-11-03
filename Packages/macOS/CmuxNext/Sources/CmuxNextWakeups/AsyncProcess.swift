public import Foundation
import CmuxNextCompat
import Darwin
import Dispatch

/// Runs a child process and awaits its end without blocking any thread.
///
/// `process.waitUntilExit()` and `readDataToEndOfFile()` park a thread until the child ends; inside a
/// `Task` that thread is one of the cooperative pool's (one per core), so a few slow `git` or `gh` runs
/// stall every task in the app. Here nothing waits: the child's output arrives through read sources on
/// one serial queue, its exit through `terminationHandler`, and the caller's continuation resumes on
/// the first of exit, timeout and cancellation (or, for a ``ProcessRequest/CancelBehavior/finish``
/// request, at the exit or the SIGKILL). Output the child wrote before it exited is all read (the exit
/// drains the pipes); a grandchild that keeps the pipe open does not hold the result. A stopped child
/// that ignores its stop signal gets SIGKILL after the request's kill grace.
///
/// ```swift
/// let outcome = try await processes.run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/git"),
///                                                      ["-C", folder, "status", "--porcelain"],
///                                                      timeout: .seconds(5)))
/// guard outcome.succeeded else { return nil }
/// ```
public struct AsyncProcess: Sendable {
    private let clock: any Clock<Duration>

    /// Creates a runner.
    ///
    /// - Parameter clock: the clock of the request's timeout and kill grace; tests pass a manual one.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Starts the request's child and returns when it has exited.
    ///
    /// `@concurrent`: the setup and the spawn (`posix_spawn` inside `Process.run()`) always run on the
    /// global executor. The module uses `NonisolatedNonsendingByDefault`, so without it this would run
    /// on the caller's actor, and every main-actor caller would spawn on the main thread.
    ///
    /// - Parameter request: what to run.
    /// - Returns: its exit status and output.
    /// - Throws: ``ProcessFailure/launch(_:)`` when it could not start, ``ProcessFailure/timedOut`` past
    ///   the request's timeout, `CancellationError` when the caller is cancelled and the request's
    ///   ``ProcessRequest/onCancel`` is ``ProcessRequest/CancelBehavior/stop`` (the child gets the
    ///   request's stop signal, then SIGKILL after its kill grace, in both cases). A
    ///   ``ProcessRequest/CancelBehavior/finish`` request ignores the caller's cancel.
    @concurrent public func run(_ request: ProcessRequest) async throws -> ProcessOutcome {
        let stopsWithCaller = request.onCancel == .stop
        if stopsWithCaller { try Task.checkCancellation() }
        let run = ProcessRun(request, clock: clock)
        let deadline = request.timeout.map { _ in DemandTimer(owner: "process.\(request.executable.lastPathComponent)", clock: clock) }
        defer { deadline?.cancel() }
        let started: () async throws -> ProcessOutcome = {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutcome, any Error>) in
                run.start(continuation)
                if let deadline, let timeout = request.timeout {
                    deadline.schedule(after: timeout) { run.stop(ProcessFailure.timedOut) }
                }
            }
        }
        guard stopsWithCaller else { return try await started() }
        return try await withTaskCancellationHandler {
            try await started()
        } onCancel: {
            run.stop(CancellationError())
        }
    }
}
