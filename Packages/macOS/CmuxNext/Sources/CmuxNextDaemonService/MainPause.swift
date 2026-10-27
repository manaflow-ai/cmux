public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// A pause of a main-actor async flow (a backoff between two retries) on a ``MainDeadline`` (recipe R-timer,
/// plans/cmux-next/chrome-parity/p06-scheduler.md): the wake is an entry of the main thread's one wake-up queue,
/// placed flexible (no sooner, in ``WakeLeeway``'s window), and the flow resumes from a task in the deadline's class,
/// not from a sleep of its own. Chromium's retries post a delayed task the same way (`net::BackoffEntry` with
/// `base::OneShotTimer`).
///
/// ```swift
/// let pauses = MainPause(owner: "CloudMachineCreateFlow.pause", workClass: .visible, scheduler: deadlines)
/// try await pauses.delay(CloudMachineCreateFlow.backoff(attempt))
/// ```
@MainActor
public final class MainPause {
    private let deadline: MainDeadline
    private let work: MainWorkScheduler
    private var continuation: OnceContinuation<Void, any Error>?
    /// Bumped by every wait, so a cancel posted for an earlier wait never ends a later one.
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - owner: The pause's owner on the board and in the wakeup ledger.
    ///   - workClass: The class the flow resumes in.
    ///   - scheduler: The app's one deadline scheduler.
    public init(owner: String, workClass: BudgetedWorkClass, scheduler: MainDeadlineScheduler) {
        deadline = MainDeadline(owner: owner, workClass: workClass, scheduler: scheduler)
        work = scheduler.work
    }

    /// A flow is suspended in ``delay(_:)`` (tests).
    public var isWaiting: Bool { continuation != nil }

    /// Returns no sooner than `delay` from now. One pause at a time: a second call ends the first one.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled first.
    public func delay(_ delay: Duration) async throws {
        try Task.checkCancellation()
        end(nil)
        generation &+= 1
        let work = work, owner = deadline.owner, workClass = deadline.workClass, current = generation
        try await withTaskCancellationHandler {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                self.continuation = continuation
                deadline.schedule(after: delay) { [weak self] in self?.end(nil) }
            }
        } onCancel: {
            work.postFromAnyThread(workClass, owner: owner) { [weak self] in self?.end(CancellationError(), of: current) }
        }
    }

    /// Resumes the waiting flow, if any (only wait `of`'s when given), with `error` or normally, and drops its deadline.
    private func end(_ error: (any Error)?, of wait: UInt64? = nil) {
        if let wait, wait != generation { return }
        deadline.cancel()
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
    }
}
