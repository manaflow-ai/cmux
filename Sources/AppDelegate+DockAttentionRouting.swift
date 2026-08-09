import AppKit
import Foundation

@MainActor
extension AppDelegate {
    enum LiveSurfaceContainer {
        case workspace
        case workspaceDock(DockSplitStore)
        case windowDock(DockSplitStore)
    }

    struct LiveSurfaceOwner {
        let tabID: UUID
        let surfaceID: UUID
        let tabManager: TabManager
        let container: LiveSurfaceContainer
    }

    /// Resolves the current owner for a surface across every live container.
    /// Workspace-scoped Docks remain valid ownership targets for process and
    /// Feed attribution even though they are no longer rendered as Docks.
    func liveSurfaceOwner(
        surfaceID: UUID,
        preferredTabID: UUID? = nil
    ) -> LiveSurfaceOwner? {
        if let preferredTabID,
           let manager = tabManagerFor(tabId: preferredTabID),
           let workspace = manager.workspacesById[preferredTabID],
           let target = workspace.surfaceOwnershipTarget(for: surfaceID) {
            return LiveSurfaceOwner(
                tabID: preferredTabID,
                surfaceID: target.surfaceID,
                tabManager: manager,
                container: .workspace
            )
        }
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(surfaceID) }) {
            let manager = dock.scope == .global
                ? tabManagerFor(windowId: dock.workspaceId)
                : tabManagerFor(tabId: dock.workspaceId)
            guard let manager else { return nil }
            let container: LiveSurfaceContainer = dock.scope == .global
                ? .windowDock(dock)
                : .workspaceDock(dock)
            return LiveSurfaceOwner(
                tabID: dock.workspaceId,
                surfaceID: surfaceID,
                tabManager: manager,
                container: container
            )
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
                return LiveSurfaceOwner(
                    tabID: workspace.id,
                    surfaceID: target.surfaceID,
                    tabManager: manager,
                    container: .workspace
                )
            }
            if let manager = tabManager,
               seenManagers.insert(ObjectIdentifier(manager)).inserted,
               let workspace = manager.tabs.first(where: {
                   $0.surfaceOwnershipTarget(for: surfaceID) != nil
               }),
               let target = workspace.surfaceOwnershipTarget(for: surfaceID) {
                return LiveSurfaceOwner(
                    tabID: workspace.id,
                    surfaceID: target.surfaceID,
                    tabManager: manager,
                    container: .workspace
                )
            }
            return nil
        }
        guard let target = owner.workspace.surfaceOwnershipTarget(for: surfaceID) else {
            return nil
        }
        return LiveSurfaceOwner(
            tabID: owner.workspace.id,
            surfaceID: target.surfaceID,
            tabManager: owner.tabManager,
            container: .workspace
        )
    }

    /// Resolves the current rendered notification owner for a surface.
    /// Legacy workspace-scoped Docks remain live for compatibility but cannot
    /// be opened without revealing a different Dock and clearing an invisible
    /// panel's attention state.
    func notificationSurfaceOwner(
        surfaceID: UUID,
        preferredTabID: UUID? = nil
    ) -> LiveSurfaceOwner? {
        guard let owner = liveSurfaceOwner(
            surfaceID: surfaceID,
            preferredTabID: preferredTabID
        ) else {
            return nil
        }
        if case .workspaceDock = owner.container {
            return nil
        }
        return owner
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
