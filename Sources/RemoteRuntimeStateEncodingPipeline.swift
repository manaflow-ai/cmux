import Foundation

/// Owns the workspace's latest-wins runtime-state encoding chain.
///
/// Superseded tasks are cancelled but still awaited before replacement work
/// starts, so cancellation cannot make synchronous `Encodable` work overlap.
/// Closing a workspace detaches the current task with ``finishPendingWork(before:)``
/// and runs the supplied finalizer only after that task has enqueued its result.
@MainActor
final class RemoteRuntimeStateEncodingPipeline {
    private var pendingTask: Task<Void, Never>?

    /// Coalesces pending work while keeping synchronous operations serialized.
    @discardableResult
    func enqueue(_ operation: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let previousTask = pendingTask
        previousTask?.cancel()
        let task = Task.detached(priority: .utility) {
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            operation()
        }
        pendingTask = task
        return task
    }

    /// Drains the current task before running a close-path finalizer.
    @discardableResult
    func finishPendingWork(
        before operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let pendingTask = pendingTask
        self.pendingTask = nil
        return Task.detached(priority: .utility) {
            if let pendingTask {
                await pendingTask.value
            }
            await operation()
        }
    }
}
