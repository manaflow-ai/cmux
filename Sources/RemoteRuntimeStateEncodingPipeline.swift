import Foundation

@MainActor
final class RemoteRuntimeStateEncodingPipeline {
    private var pendingTask: Task<Void, Never>?

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

    @discardableResult
    func finishPendingWork(
        before operation: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        let pendingTask = pendingTask
        self.pendingTask = nil
        return Task.detached(priority: .utility) {
            if let pendingTask {
                await pendingTask.value
            }
            operation()
        }
    }
}
