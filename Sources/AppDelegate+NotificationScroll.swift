import Bonsplit
import Foundation

@MainActor
extension AppDelegate {
    static func notificationNavSnapshot(_ notification: TerminalNotification) -> NotificationNavSnapshot {
        NotificationNavSnapshot(
            id: notification.id,
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            panelId: notification.panelId,
            isRead: notification.isRead,
            clickAction: notification.clickAction.map(navClickAction),
            scrollRow: notification.scrollPosition?.row,
            scrollTotalRows: notification.scrollPosition?.totalRows,
            scrollReplayGeneration: notification.scrollPosition?.replayGeneration,
            scrollRowSpaceRevision: notification.scrollPosition?.rowSpaceRevision
        )
    }

    func navScrollPosition(
        row: Int?,
        totalRows: Int?,
        replayGeneration: String?,
        rowSpaceRevision: UInt64?
    ) -> TerminalNotificationScrollPosition? {
        guard let row else { return nil }
        return TerminalNotificationScrollPosition(
            row: row,
            totalRows: totalRows,
            replayGeneration: replayGeneration,
            rowSpaceRevision: rowSpaceRevision
        )
    }

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
        if let panelId, let panel = workspace.panels[panelId] as? TerminalPanel {
            return panel
        }
        if let surfaceId {
            if let panel = workspace.panels[surfaceId] as? TerminalPanel {
                return panel
            }
            return workspace.panelIdFromSurfaceId(TabID(uuid: surfaceId))
                .flatMap { workspace.panels[$0] as? TerminalPanel }
        }
        return workspace.focusedPanelId.flatMap { workspace.panels[$0] as? TerminalPanel }
    }
}
