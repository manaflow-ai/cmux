import Foundation

extension TerminalNotificationStore {
    static func insertionIndex(
        for notification: TerminalNotification,
        in notifications: [TerminalNotification]
    ) -> Int {
        var lowerBound = 0
        var upperBound = notifications.count
        while lowerBound < upperBound {
            let candidate = lowerBound + (upperBound - lowerBound) / 2
            if notificationSortPrecedes(notification, notifications[candidate]) {
                upperBound = candidate
            } else {
                lowerBound = candidate + 1
            }
        }
        return lowerBound
    }

    static func insertNotification(
        _ notification: TerminalNotification,
        into indexes: inout NotificationIndexes,
        notifications: [TerminalNotification]
    ) {
        let expectedPreviousCount = notifications.count - 1
        guard indexes.ids.count == expectedPreviousCount,
              indexes.ids.insert(notification.id).inserted else {
#if DEBUG
            cmuxDebugLog(
                "notification.indexes.recover function=insertNotification " +
                    "notificationId=\(notification.id.uuidString) " +
                    "indexedCount=\(indexes.ids.count) expectedPreviousCount=\(expectedPreviousCount)"
            )
#endif
            indexes = buildIndexes(for: notifications)
            return
        }
        let tabSurfaceKey = TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
        if indexes.latestByTabId[notification.tabId].map({ notificationSortPrecedes(notification, $0) }) ?? true {
            indexes.latestByTabId[notification.tabId] = notification
        }
        if indexes.latestByTabSurface[tabSurfaceKey].map({ notificationSortPrecedes(notification, $0) }) ?? true {
            indexes.latestByTabSurface[tabSurfaceKey] = notification
        }
        guard !notification.isRead else { return }
        indexes.unreadCount += 1
        indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
        indexes.unreadByTabSurface.insert(tabSurfaceKey)
        if let panelId = notification.panelId, panelId != notification.surfaceId {
            indexes.unreadByTabSurface.insert(TabSurfaceKey(tabId: notification.tabId, surfaceId: panelId))
        }
        if indexes.latestUnreadByTabId[notification.tabId].map({ notificationSortPrecedes(notification, $0) }) ?? true {
            indexes.latestUnreadByTabId[notification.tabId] = notification
        }
    }

    nonisolated static func notificationSortPrecedes(
        _ lhs: TerminalNotification,
        _ rhs: TerminalNotification
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func dockBadgeLabel(
        unreadCount: Int,
        isEnabled: Bool,
        runTag: String? = nil
    ) -> String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            return unreadCount > 99 ? "99+" : String(unreadCount)
        }()
        if let tag = TaggedRunBadgeSettings.normalizedTag(runTag) {
            return unreadLabel.map { "\(tag):\($0)" } ?? tag
        }
        return unreadLabel
    }
}
