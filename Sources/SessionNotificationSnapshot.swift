import Foundation

struct SessionNotificationSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var body: String
    var createdAt: TimeInterval
    var isRead: Bool
    var paneFlash: Bool?
    var retargetsToLiveSurfaceOwner: Bool?
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        isRead: Bool,
        paneFlash: Bool? = nil,
        retargetsToLiveSurfaceOwner: Bool? = nil,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
    }

    init(notification: TerminalNotification) {
        let persistedScrollPosition = notification.scrollPosition.map {
            TerminalNotificationScrollPosition(row: $0.row, totalRows: $0.totalRows)
        }
        self.init(
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt.timeIntervalSince1970,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            scrollPosition: persistedScrollPosition,
            clickAction: notification.clickAction
        )
    }

    func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        let restoredScrollPosition = scrollPosition.map {
            TerminalNotificationScrollPosition(row: $0.row, totalRows: $0.totalRows)
        }
        return TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner ?? true,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            paneFlash: paneFlash ?? true,
            scrollPosition: restoredScrollPosition,
            clickAction: clickAction
        )
    }
}
