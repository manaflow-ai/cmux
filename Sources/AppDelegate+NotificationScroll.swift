import Bonsplit
import Foundation

@MainActor
extension AppDelegate {
    func terminalNotificationScrollPosition(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?
    ) -> TerminalNotificationScrollPosition? {
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

    private func terminalPanelForNotificationScroll(
        workspace: Workspace,
        surfaceId: UUID?,
        panelId: UUID?
    ) -> TerminalPanel? {
        if let panelId,
           let panel = workspace.terminalInputTarget(forPanelID: panelId)?.panel {
            return panel
        }
        if let surfaceId {
            if let panel = workspace.terminalInputTarget(forPanelID: surfaceId)?.panel {
                return panel
            }
            return workspace.panelIdFromSurfaceId(TabID(uuid: surfaceId))
                .flatMap { workspace.terminalInputTarget(forPanelID: $0)?.panel }
        }
        return workspace.focusedTerminalInputTarget()?.panel
    }
}
