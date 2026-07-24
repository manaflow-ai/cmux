import CmuxNotifications

extension TerminalNotification {
    /// Converts app notification state into the value consumed by navigation.
    var notificationNavigationSnapshot: NotificationNavSnapshot {
        NotificationNavSnapshot(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            isRead: isRead,
            clickAction: clickAction?.notificationNavigationAction,
            scrollRow: scrollPosition?.row,
            scrollTotalRows: scrollPosition?.totalRows,
            scrollRowSpaceRevision: scrollPosition?.rowSpaceRevision
        )
    }
}

extension TerminalNotificationClickAction {
    /// Converts an app click action into the value consumed by navigation.
    var notificationNavigationAction: NotificationNavClickAction {
        switch self {
        case .revealInFinder(let path):
            .revealInFinder(path: path)
        }
    }
}
