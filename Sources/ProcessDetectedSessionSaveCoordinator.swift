import Foundation

/// Owns cancellation and generation fencing for asynchronous process-indexed saves.
@MainActor
final class ProcessDetectedSessionSaveCoordinator {
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    /// Starts a new save generation and invalidates an older save.
    func beginGeneration() -> UInt64 {
        task?.cancel()
        task = nil
        generation &+= 1
        return generation
    }

    /// Replaces the currently running save task for this coordinator.
    func replaceTask(_ task: Task<Void, Never>) {
        self.task?.cancel()
        self.task = task
    }

    /// Cancels the pending save and invalidates its generation.
    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }

    /// Returns whether a completion still belongs to the latest save request.
    func isCurrentGeneration(_ generation: UInt64) -> Bool {
        self.generation == generation
    }
}
