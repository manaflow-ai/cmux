import Foundation

@MainActor
final class RemoteRuntimeStateEncodingPipeline {
    private var pendingTask: Task<Void, Never>?

    @discardableResult
    func enqueue(_ operation: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        pendingTask?.cancel()
        let task = Task.detached(priority: .utility) {
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
        operation()
        return Task {}
    }
}
