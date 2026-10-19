import Foundation

@MainActor
extension AppDelegate {
    func terminalNotificationScrollPosition(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?
    ) -> TerminalNotificationScrollPosition? {
        if let surfaceId,
           let dock = existingWindowDock(forWindowId: tabId),
           let panel = dock.panels[surfaceId] as? TerminalPanel {
            return panel.notificationScrollPosition
        }
        guard let workspace = workspaceFor(tabId: tabId) ?? tabManager?.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }
        return terminalPanelForNotificationScroll(workspace: workspace, surfaceId: surfaceId, panelId: panelId)?
            .notificationScrollPosition
    }

    func restoreNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition?,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        workspace: Workspace?
    ) {
        guard let workspace = workspace ?? workspaceFor(tabId: tabId) ?? tabManager?.tabs.first(where: { $0.id == tabId }) else {
            return
        }
        _ = terminalPanelForNotificationScroll(workspace: workspace, surfaceId: surfaceId, panelId: panelId)?
            .restoreNotificationScrollPosition(position)
    }

    func restoreWindowDockNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition?,
        dock: DockSplitStore,
        panelId: UUID
    ) {
        guard let panel = dock.panels[panelId] as? TerminalPanel else { return }
        _ = panel.restoreNotificationScrollPosition(position)
    }

    private func terminalPanelForNotificationScroll(
        workspace: Workspace,
        surfaceId: UUID?,
        panelId: UUID?
    ) -> TerminalPanel? {
        // The surface is the exact notification identity. `panelId` is only a
        // stable container fallback and may represent a remote-tmux window
        // whose active pane changed after the notification was recorded.
        if let surfaceId,
           let panel = workspace.terminalInputTarget(forPanelID: surfaceId)?.panel {
            return panel
        }
        if let surfaceId,
           let mappedPanelID = workspace.panelId(forSurfaceId: surfaceId),
           let panel = workspace.terminalInputTarget(forPanelID: mappedPanelID)?.panel {
            return panel
        }
        if let panelId,
           let panel = workspace.terminalInputTarget(forPanelID: panelId)?.panel {
            return panel
        }
        return workspace.focusedTerminalInputTarget()?.panel
    }
}
