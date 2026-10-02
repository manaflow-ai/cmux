import Bonsplit
import Foundation

extension Workspace {
    /// Rebuilds a transferred Dock panel through its original workspace, then detaches the
    /// live panel so the Dock can adopt the same remote transport and agent lifecycle state.
    func detachedSurfaceForDockSessionRestore(
        _ snapshot: SessionPanelSnapshot,
        snapshotWorkspaceId: UUID,
        excludingStableIdentities: Set<UUID>
    ) -> DetachedSurfaceTransfer? {
        guard let paneId = bonsplitController.allPaneIds.first else { return nil }
        sessionRestoreIdentityExclusions.beginRestore(excluding: excludingStableIdentities)
        defer { sessionRestoreIdentityExclusions.endRestore() }
        guard let panelId = createPanel(
            from: snapshot,
            inPane: paneId,
            snapshotWorkspaceId: snapshotWorkspaceId,
            shouldRestoreSingleDefaultCloudTerminal: false
        ) else {
            return nil
        }
        return detachSurface(panelId: panelId)
    }
}
