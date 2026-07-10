import Foundation

/// Owns the one in-flight foreground-command enrichment for a window's Save Workspace action.
@MainActor
final class WorkspaceActionSaveCaptureCoordinator {
    typealias LiveCommandLoader = @Sendable (Set<Int64>) async -> [Int64: String]
    typealias ReadyHandler = @MainActor (WorkspaceConfigActionSnapshot, String) -> Void

    private var generation: UInt64 = 0
    private var pendingTask: Task<Void, Never>?

    /// Starts a latest-wins save capture and returns its task for deterministic observation.
    @discardableResult
    func begin(
        capture: WorkspaceConfigActionCapture,
        loadLiveCommands: @escaping LiveCommandLoader,
        onReady: @escaping ReadyHandler
    ) -> Task<Void, Never> {
        generation &+= 1
        let requestedGeneration = generation
        pendingTask?.cancel()

        let task = Task { @MainActor [weak self] in
            let liveCommandsByTTY = await loadLiveCommands(capture.ttyDevices)
            guard !Task.isCancelled,
                  let self,
                  self.generation == requestedGeneration else { return }

            let snapshot = await Task.detached(priority: .userInitiated) {
                capture.enrichedSnapshot(liveCommandsByTTY: liveCommandsByTTY)
            }.value
            guard !Task.isCancelled,
                  self.generation == requestedGeneration else { return }

            self.pendingTask = nil
            onReady(snapshot, capture.initialName)
        }
        pendingTask = task
        return task
    }
}
