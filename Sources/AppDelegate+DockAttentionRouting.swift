import AppKit
import Foundation

@MainActor
extension AppDelegate {
    /// Resolves the current notification owner for a surface across every
    /// container. Dock IDs are stable notification namespaces (`workspaceId`
    /// is the workspace ID for a workspace Dock and the window ID for a global
    /// Dock); main-tree surfaces keep the existing workspace owner.
    func notificationSurfaceOwner(
        surfaceID: UUID,
        preferredTabID: UUID? = nil
    ) -> (tabID: UUID, surfaceID: UUID, tabManager: TabManager)? {
        if let preferredTabID,
           let manager = tabManagerFor(tabId: preferredTabID),
           let workspace = manager.workspacesById[preferredTabID],
           let target = workspace.surfaceOwnershipTarget(for: surfaceID) {
            return (preferredTabID, target.surfaceID, manager)
        }
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(surfaceID) }) {
            let manager = dock.scope == .global
                ? tabManagerFor(windowId: dock.workspaceId)
                : tabManagerFor(tabId: dock.workspaceId)
            guard let manager else { return nil }
            return (dock.workspaceId, surfaceID, manager)
        }
        guard let owner = workspaceContainingPanel(
            panelId: surfaceID,
            preferredWorkspaceId: preferredTabID
        ) else {
            var seenManagers = Set<ObjectIdentifier>()
            for summary in listMainWindowSummaries() {
                guard let manager = tabManagerFor(windowId: summary.windowId),
                      seenManagers.insert(ObjectIdentifier(manager)).inserted,
                      let workspace = manager.tabs.first(where: {
                          $0.surfaceOwnershipTarget(for: surfaceID) != nil
                      }),
                      let target = workspace.surfaceOwnershipTarget(for: surfaceID) else {
                    continue
                }
                return (workspace.id, target.surfaceID, manager)
            }
            if let manager = tabManager,
               seenManagers.insert(ObjectIdentifier(manager)).inserted,
               let workspace = manager.tabs.first(where: {
                   $0.surfaceOwnershipTarget(for: surfaceID) != nil
               }),
               let target = workspace.surfaceOwnershipTarget(for: surfaceID) {
                return (workspace.id, target.surfaceID, manager)
            }
            return nil
        }
        guard let target = owner.workspace.surfaceOwnershipTarget(for: surfaceID) else {
            return nil
        }
        return (owner.workspace.id, target.surfaceID, owner.tabManager)
    }

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
            shouldFocus: shouldFocus
        ) {
            return true
        }

        guard let workspace = workspaceFor(tabId: workspaceID) ??
                tabManager?.tabs.first(where: { $0.id == workspaceID }),
              let target = workspace.surfaceOwnershipTarget(for: panelID),
              target.panel.panelType == .terminal else {
            return false
        }
        if shouldFocus {
            workspace.focusPanel(target.surfaceID)
        }
        if requiresSplit,
           workspace.bonsplitController.allPaneIds.count <= 1,
           workspace.panels.count <= 1 {
            return true
        }
        target.panel.triggerFlash(reason: reason)
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
