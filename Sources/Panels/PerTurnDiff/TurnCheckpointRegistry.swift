import Foundation

/// One TurnCheckpointManager per active workspace.
/// Lifecycle owned by TabManager via attach/detach calls.
/// Mirrors the pattern of TabManager.wireClosedBrowserTracking.
@MainActor
final class TurnCheckpointRegistry {
    static let shared = TurnCheckpointRegistry()

    private var managers: [UUID: TurnCheckpointManager] = [:]

    private init() {}

    func attach(workspace: Workspace) {
        guard managers[workspace.id] == nil else { return }
        let mgr = TurnCheckpointManager(workspace: workspace)
        managers[workspace.id] = mgr
        mgr.start()
    }

    func detach(workspaceId: UUID) {
        guard let mgr = managers.removeValue(forKey: workspaceId) else { return }
        mgr.stop()
    }

    func manager(for workspaceId: UUID) -> TurnCheckpointManager? {
        managers[workspaceId]
    }
}
