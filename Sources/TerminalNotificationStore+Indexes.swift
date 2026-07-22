import Foundation

extension TerminalNotificationStore {
#if DEBUG
    private static var fullIndexRebuildCount = 0

    static func resetFullIndexRebuildCountForTesting() {
        fullIndexRebuildCount = 0
    }

    static var fullIndexRebuildCountForTesting: Int { fullIndexRebuildCount }
#endif

    static func indexByIdPreservingFirst<Notifications: Sequence>(
        _ notifications: Notifications
    ) -> [UUID: TerminalNotification] where Notifications.Element == TerminalNotification {
        Dictionary(notifications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func buildIndexes<Notifications: Sequence>(
        for notifications: Notifications
    ) -> NotificationIndexes where Notifications.Element == TerminalNotification {
#if DEBUG
        fullIndexRebuildCount += 1
#endif
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
            let unreadKeys = unreadIndexKeys(for: notification)
            for key in unreadKeys {
                indexes.unreadCountByTabSurface[key, default: 0] += 1
                indexes.unreadByTabSurface.insert(key)
            }
        }
        return indexes
    }

    static func unreadIndexKeys(for notification: TerminalNotification) -> Set<TabSurfaceKey> {
        var keys: Set<TabSurfaceKey> = [
            TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
        ]
        if let panelId = notification.panelId {
            keys.insert(TabSurfaceKey(tabId: notification.tabId, surfaceId: panelId))
        }
        return keys
    }
}
