import Foundation

/// Serializes camera cleanup across worker-client replacement. A replacement
/// client observes the same tail task and cannot configure injection until an
/// older client's cleanup has stopped mutating Simulator application state.
actor SimulatorCameraCleanupCoordinator {
    private var tail: Task<Void, Never>?
    private var revision: UInt64 = 0

    func enqueue(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        revision &+= 1
        let taskRevision = revision
        tail = task
        Task { [weak self] in
            await task.value
            await self?.clearTail(revision: taskRevision)
        }
        return task
    }

    func currentTask() -> Task<Void, Never>? {
        tail
    }

    private func clearTail(revision: UInt64) {
        guard self.revision == revision else { return }
        tail = nil
    }
}
