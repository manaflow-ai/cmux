import Foundation

extension TerminalNotificationStore {
    static func indexByIdPreservingFirst(_ notifications: [TerminalNotification]) -> [UUID: TerminalNotification] {
        Dictionary(notifications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func buildIndexes(for notifications: [TerminalNotification]) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            indexes.ids.insert(notification.id)
            if indexes.latestByTabId[notification.tabId] == nil {
                indexes.latestByTabId[notification.tabId] = notification
            }
            let tabSurfaceKey = TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            if indexes.latestByTabSurface[tabSurfaceKey] == nil {
                indexes.latestByTabSurface[tabSurfaceKey] = notification
            }
            guard !notification.isRead else { continue }
            indexes.unreadCount += 1
            indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if let panelId = notification.panelId, panelId != notification.surfaceId {
                indexes.unreadByTabSurface.insert(TabSurfaceKey(tabId: notification.tabId, surfaceId: panelId))
            }
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
    }
}
