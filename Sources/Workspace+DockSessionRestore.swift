import Bonsplit
import Foundation

extension Workspace {
    /// Rebuilds a transferred Dock panel through its original workspace, then detaches the
    /// live panel so the Dock can adopt the same remote transport and agent lifecycle state.
    func detachedSurfaceForDockSessionRestore(
        _ snapshot: SessionPanelSnapshot,
        snapshotWorkspaceId: UUID,
        excludingStableIdentities: Set<UUID>,
        restorableAgentIndex: RestorableAgentSessionIndex?,
        claudeBackgroundRestores: [UUID: ClaudeBackgroundAttachRestore]? = nil
    ) -> DetachedSurfaceTransfer? {
        guard let paneId = bonsplitController.allPaneIds.first else { return nil }
        sessionRestoreIdentityExclusions.beginRestore(excluding: excludingStableIdentities)
        defer { sessionRestoreIdentityExclusions.endRestore() }
        // A Dock restore pass already chose one pane per Claude background
        // session across the whole Dock; this panel follows that plan rather
        // than planning itself alone.
        let previousClaudeBackgroundRestores = claudeBackgroundAttachRestoresByStablePanelID
        if let claudeBackgroundRestores {
            claudeBackgroundAttachRestoresByStablePanelID = claudeBackgroundRestores
        }
        defer { claudeBackgroundAttachRestoresByStablePanelID = previousClaudeBackgroundRestores }
        guard let panelId = createPanel(
            from: snapshot,
            inPane: paneId,
            snapshotWorkspaceId: snapshotWorkspaceId,
            shouldRestoreSingleDefaultCloudTerminal: false,
            restorableAgentIndex: restorableAgentIndex
        ) else {
            return nil
        }
        guard let detached = detachSurface(panelId: panelId) else {
            terminalStartupRestoreCoordinator.cancelPendingRestore(panelID: panelId)
            _ = closePanel(panelId, force: true)
            return nil
        }
        return detached
    }
}
