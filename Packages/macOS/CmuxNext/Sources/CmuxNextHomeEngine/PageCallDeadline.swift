import CmuxNextWakeups
import Foundation

/// A page call that answers by a deadline, also when its work never ends: the first of the work's
/// end, the deadline and the caller's cancel answers (one ``FirstOutcome``). The deadline is a
/// ``DemandTimer`` on the injected clock, so a test moves time without waiting. The work's task is
/// cancelled once the call answered; a late result is dropped. `onTimeout` runs only when the
/// deadline answered.
@MainActor
enum PageCallDeadline {
    private nonisolated enum Outcome<T: Sendable>: Sendable {
        case finished(Result<T, any Error>)
        case timedOut
        case cancelled
    }

    static func answer<T: Sendable>(within deadline: Duration, clock: any Clock<Duration>,
                                    onTimeout: @escaping @MainActor @Sendable () -> any Error,
                                    _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let outcome = FirstOutcome<Outcome<T>>()
        let timer = DemandTimer(owner: "PageCallDeadline", clock: clock)
        // task-owner: the call's work; cancelled below once the call answered
        let task = Task { @MainActor in
            let result: Result<T, any Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            outcome.resolve(.finished(result))
        }
        timer.schedule(after: deadline) { outcome.resolve(.timedOut) }
        let first = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            // The page cancelled the call (navigation, tab close): its work stops sending too.
            outcome.resolve(.cancelled)
        }
        timer.cancel()
        task.cancel()
        switch first {
        case .finished(let result): return try result.get()
        case .timedOut: throw onTimeout()
        case .cancelled: throw CancellationError()
        }
    }
}
