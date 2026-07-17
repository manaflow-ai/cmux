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
            websiteClickTarget: websiteClickTarget,
            scrollRow: scrollPosition?.row,
            scrollTotalRows: scrollPosition?.totalRows,
            scrollRowSpaceRevision: scrollPosition?.rowSpaceRevision
        )
    }

    private var websiteClickTarget: NotificationNavWebsiteClickTarget? {
        guard case .website(let displayOrigin) = source else { return nil }
        return NotificationNavWebsiteClickTarget(displayOrigin: displayOrigin)
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
