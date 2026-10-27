public import Foundation

/// Runs a ``ProcessRequest`` to its end: ``AsyncProcess`` in the app; a test passes a fake that records each
/// request (its ``ProcessRequest/priority`` too) and answers with no child.
///
/// ```swift
/// let outcome = try await processes.outcome(of: ProcessRequest(ditto, arguments, priority: .userVisible))
/// ```
public protocol ProcessRunning: Sendable {
    /// Starts the request's child and returns when it has exited, as ``AsyncProcess/run(_:)`` does.
    func outcome(of request: ProcessRequest) async throws -> ProcessOutcome
}

extension AsyncProcess: ProcessRunning {
    /// ``run(_:)``: the spawn and the wait never run on the caller's actor.
    public func outcome(of request: ProcessRequest) async throws -> ProcessOutcome {
        try await run(request)
    }
}

extension ProcessRunning {
    /// Runs `request` and waits at most `limit` for its end; nil when the limit passes or the caller is
    /// cancelled first. The child is not stopped then: it runs on to its exit, for a job that must not end
    /// half way (a chat move, a home adoption). Give such a request ``ProcessRequest/CancelBehavior/finish``
    /// and no timeout.
    ///
    /// - Parameters:
    ///   - request: what to run.
    ///   - limit: how long the caller waits.
    ///   - owner: the limit's name in the wakeup ledger.
    ///   - clock: the limit's clock; tests pass a manual one.
    /// - Returns: the child's outcome, or nil when the caller stopped waiting.
    /// - Throws: the run's error (``ProcessFailure/launch(_:)``) when it came within the limit.
    public func outcome(of request: ProcessRequest, waitingAtMost limit: Duration, owner: String,
                        clock: any Clock<Duration> = ContinuousClock()) async throws -> ProcessOutcome? {
        let first = FirstOutcome<Result<ProcessOutcome, any Error>?>()
        let processes = self
        // task-owner: the child's own run; it outlives a wait that gave up and ends at the child's exit
        Task {
            do {
                let outcome = try await processes.outcome(of: request)
                first.resolve(.success(outcome))
            } catch {
                first.resolve(.failure(error))
            }
        }
        // timer-class-allow: off main: the caller's wait bound only resolves the first outcome
        let bound = DemandTimer(owner: owner, clock: clock)
        bound.schedule(after: limit) { first.resolve(nil) }
        defer { bound.cancel() }
        let result = await withTaskCancellationHandler {
            await first.value()
        } onCancel: {
            first.resolve(nil)
        }
        return try result?.get()
    }
}
