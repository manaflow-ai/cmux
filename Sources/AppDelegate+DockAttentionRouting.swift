import AppKit
import Foundation

@MainActor
extension AppDelegate {
    /// Shared notification-attention route for every surface container. Dock
    /// stores resolve first through their live registry; workspace panels use
    /// the existing attention coordinator and pane-overlay path.
    @discardableResult
    func routeNotificationAttentionFlash(
        workspaceID: UUID,
        panelID: UUID,
        reason: WorkspaceAttentionFlashReason,
        requiresSplit: Bool = false,
        shouldFocus: Bool = false
    ) -> Bool {
        if DockSplitStore.routeAttentionFlash(
            panelID: panelID,
            reason: reason,
            requiresSplit: requiresSplit,
            shouldFocus: shouldFocus
        ) {
            return true
        }

        guard let workspace = workspaceFor(tabId: workspaceID) ??
                tabManager?.tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.panels[panelID],
              panel.panelType == .terminal else {
            return false
        }
        if shouldFocus {
            workspace.focusPanel(panelID)
        }
        if requiresSplit,
           workspace.bonsplitController.allPaneIds.count <= 1,
           workspace.panels.count <= 1 {
            return true
        }
        workspace.requestAttentionFlash(panelId: panelID, reason: reason)
        return true
    }

    /// Resolves the surface whose unread notification becomes visible when the
    /// app activates. The key window's focused global Dock wins when the Dock
    /// owns input focus; otherwise the selected workspace keeps the existing
    /// focused-main-surface behavior.
    func notificationAttentionTargetOnActivation(
        tabManager: TabManager
    ) -> (workspaceID: UUID, surfaceID: UUID)? {
        if let dock = focusedDockStoreForShortcut(preferredWindow: NSApp.keyWindow),
           let surfaceID = dock.focusedPanelId {
            return (dock.workspaceId, surfaceID)
        }
        guard let workspaceID = tabManager.selectedTabId,
              let surfaceID = tabManager.focusedSurfaceId(for: workspaceID) else {
            return nil
        }
        return (workspaceID, surfaceID)
    }
}
