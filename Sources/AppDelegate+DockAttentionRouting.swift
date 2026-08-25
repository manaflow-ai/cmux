import AppKit
import CMUXAgentLaunch
import Foundation

@MainActor
extension AppDelegate {
    /// Authorizes a hook notification against the panel's live runtime owner.
    /// Resolution happens at the final main-actor mutation boundary so a pane
    /// move cannot redirect stale authority onto its destination.
    func allowsAgentNotificationRuntimeMutation(
        claimedTabID: UUID,
        surfaceID: UUID,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    ) -> Bool {
        guard let runtimeKey else { return true }
        guard let authority = agentNotificationRuntimeAuthority(
            claimedTabID: claimedTabID,
            surfaceID: surfaceID,
            runtimeKey: runtimeKey
        ) else {
            return false
        }
        return authority.owner.allowsAgentRuntimeMutation(
            statusKey: authority.sessionKey.statusKey,
            runtimeKey: runtimeKey,
            runtimeGeneration: runtimeGeneration,
            panelId: authority.surfaceID
        )
    }

    /// Authorizes a panel-scoped notification clear against either the current
    /// runtime or a just-retired runtime when no replacement is current.
    func allowsAgentNotificationRuntimeCleanup(
        claimedTabID: UUID,
        surfaceID: UUID,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    ) -> Bool {
        guard let runtimeKey else { return true }
        guard let authority = agentNotificationRuntimeAuthority(
            claimedTabID: claimedTabID,
            surfaceID: surfaceID,
            runtimeKey: runtimeKey
        ) else {
            return false
        }
        return authority.owner.allowsAgentNotificationCleanup(
            statusKey: authority.sessionKey.statusKey,
            runtimeKey: runtimeKey,
            runtimeGeneration: runtimeGeneration,
            panelId: authority.surfaceID
        )
    }

    private func agentNotificationRuntimeAuthority(
        claimedTabID: UUID,
        surfaceID: UUID,
        runtimeKey: String
    ) -> (
        owner: ControlSidebarPanelOwner,
        sessionKey: AgentRuntimeSessionKey,
        surfaceID: UUID
    )? {
        guard let sessionKey = AgentRuntimeSessionKey(rawValue: runtimeKey),
              let target = liveSurfaceOwner(
                  surfaceID: surfaceID,
                  preferredTabID: claimedTabID
              ) else {
            return nil
        }
        let owner: ControlSidebarPanelOwner
        if let dock = DockSplitStore.liveStores.first(where: {
            $0.containsPanel(target.surfaceID)
        }) {
            owner = .dock(dock)
        } else if let workspace = target.tabManager.workspacesById[target.tabID],
                  workspace.panels.keys.contains(target.surfaceID) {
            owner = .workspace(workspace)
        } else {
            return nil
        }
        return (owner, sessionKey, target.surfaceID)
    }

    /// Resolves the current owner for a surface across every live container.
    /// Workspace-scoped Docks remain valid ownership targets for process and
    /// Feed attribution even though they are no longer rendered as Docks.
    func liveSurfaceOwner(
        surfaceID: UUID,
        preferredTabID: UUID? = nil
    ) -> (
        tabID: UUID,
        surfaceID: UUID,
        tabManager: TabManager,
        windowDock: DockSplitStore?,
        isNotificationRenderable: Bool
    )? {
        if let preferredTabID,
           let manager = tabManagerFor(tabId: preferredTabID),
           let workspace = manager.workspacesById[preferredTabID],
           let target = workspace.surfaceOwnershipTarget(for: surfaceID) {
            return (preferredTabID, target.surfaceID, manager, nil, true)
        }
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(surfaceID) }) {
            let manager = dock.scope == .global
                ? tabManagerFor(windowId: dock.workspaceId)
                : tabManagerFor(tabId: dock.workspaceId)
            guard let manager else { return nil }
            let isNotificationRenderable = dock.scope == .global
            return (
                dock.workspaceId,
                surfaceID,
                manager,
                isNotificationRenderable ? dock : nil,
                isNotificationRenderable
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
                return (workspace.id, target.surfaceID, manager, nil, true)
            }
            if let manager = tabManager,
               seenManagers.insert(ObjectIdentifier(manager)).inserted,
               let workspace = manager.tabs.first(where: {
                   $0.surfaceOwnershipTarget(for: surfaceID) != nil
               }),
               let target = workspace.surfaceOwnershipTarget(for: surfaceID) {
                return (workspace.id, target.surfaceID, manager, nil, true)
            }
            return nil
        }
        guard let target = owner.workspace.surfaceOwnershipTarget(for: surfaceID) else {
            return nil
        }
        return (owner.workspace.id, target.surfaceID, owner.tabManager, nil, true)
    }

    /// Resolves the current rendered notification owner for a surface.
    /// Legacy workspace-scoped Docks remain live for compatibility but cannot
    /// be opened without revealing a different Dock and clearing an invisible
    /// panel's attention state.
    func notificationSurfaceOwner(
        surfaceID: UUID,
        preferredTabID: UUID? = nil
    ) -> (
        tabID: UUID,
        surfaceID: UUID,
        tabManager: TabManager,
        windowDock: DockSplitStore?
    )? {
        guard let owner = liveSurfaceOwner(
            surfaceID: surfaceID,
            preferredTabID: preferredTabID
        ), owner.isNotificationRenderable else {
            return nil
        }
        return (
            owner.tabID,
            owner.surfaceID,
            owner.tabManager,
            owner.windowDock
        )
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
