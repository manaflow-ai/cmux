import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// A page call that answers by a deadline, also when its work never ends: the first of the work's
/// end and the deadline answers (once). The deadline is a ``DemandTimer`` on the injected clock, so
/// a test moves time without waiting. The work's task is cancelled when the deadline or the
/// caller's cancel answers; a late result is dropped.
@MainActor
enum PageCallDeadline {
    static func answer<T: Sendable>(within deadline: Duration, clock: any Clock<Duration>,
                                    onTimeout: @escaping @MainActor @Sendable () -> any Error,
                                    _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        // Cancelled before it started: no work runs.
        try Task.checkCancellation()
        guard let answered = await first(of: work, within: deadline, clock: clock) else {
            // The page cancelled the call (navigation, tab close), or the deadline passed.
            throw Task.isCancelled ? CancellationError() : onTimeout()
        }
        return try answered.get()
    }

    /// The work's result, or nil when the deadline or the caller's cancel came first; the work is cancelled
    /// then. Both cancel the wait, which ends its cancellable continuation at once and makes the work's late
    /// result a no-op. Off the main actor: only the work runs there, in its own isolation.
    private nonisolated static func first<T: Sendable>(of work: @escaping @MainActor @Sendable () async throws -> T,
                                                       within deadline: Duration,
                                                       clock: any Clock<Duration>) async -> Result<T, any Error>? {
        // task-owner: the call's work; cancelled when the deadline or the caller's cancel answers first
        let running = Task { try await work() }
        // task-owner: the wait for `running`; ends with its result, at the deadline, or at the caller's cancel
        let wait = Task {
            try await withOnceThrowingContinuation(cancellation: .cancellable) {
                (answer: OnceContinuation<Result<T, any Error>, any Error>) in
                // task-owner: hands the work's end to the wait; ends with the work
                Task { answer.resume(returning: await running.result) }
            }
        }
        let timer = DemandTimer(owner: "PageCallDeadline", clock: clock)
        timer.schedule(after: deadline) { wait.cancel() }
        let answered = await withTaskCancellationHandler {
            try? await wait.value
        } onCancel: {
            wait.cancel()
        }
        timer.cancel()
        if answered == nil { running.cancel() }
        return answered
    }
}
