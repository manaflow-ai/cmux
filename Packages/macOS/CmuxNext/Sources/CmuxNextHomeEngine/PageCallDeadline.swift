import CmuxNextWakeups
import Foundation

/// A page call that answers by a deadline, also when its work never ends: the first of the work's
/// end and the deadline answers (once). The deadline is a ``DemandTimer`` on the injected clock, so
/// a test moves time without waiting. The work's task is cancelled when the deadline or the
/// caller's cancel answers; a late result is dropped.
@MainActor
enum PageCallDeadline {
    static func answer<T: Sendable>(within deadline: Duration, clock: any Clock<Duration>,
                                    onTimeout: @escaping @MainActor @Sendable () -> any Error,
                                    _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let once = Once<T>()
        let timer = DemandTimer(owner: "PageCallDeadline", clock: clock)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancelled before it started: the cancel handler found nothing to answer.
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                once.continuation = continuation
                // task-owner: the call's work; cancelled when the deadline or the caller's cancel answers first
                once.task = Task { @MainActor in
                    let result: Result<T, any Error>
                    do { result = .success(try await work()) } catch { result = .failure(error) }
                    once.finish(result)
                }
                timer.schedule(after: deadline) { @MainActor in
                    guard once.isWaiting else { return }
                    once.finish(.failure(onTimeout()))
                }
            }
        } onCancel: {
            // The page cancelled the call (navigation, tab close): its work stops sending too.
            // task-owner: one hop onto the main actor to answer and cancel the work
            Task { @MainActor in once.finish(.failure(CancellationError())) }
        }
    }

    /// The continuation and the work's task; the first ``finish(_:)`` resumes, later ones are dropped.
    @MainActor
    private final class Once<T: Sendable> {
        var continuation: CheckedContinuation<T, any Error>?
        var task: Task<Void, Never>?

        var isWaiting: Bool { continuation != nil }

        // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14: the
        // isolated deinit's back-deploy path crashes swift-frontend's Release inliner (EarlyPerfInliner);
        // this one touches nothing.
        nonisolated deinit {}

        func finish(_ result: Result<T, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            task?.cancel()
            continuation.resume(with: result)
        }
    }
}
