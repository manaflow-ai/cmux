import Foundation

extension TerminalNotificationStore {
    static func insertionIndex<Notifications: RandomAccessCollection>(
        for notification: TerminalNotification,
        in notifications: Notifications
    ) -> Int where Notifications.Element == TerminalNotification, Notifications.Index == Int {
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

    static func insertNotification<Notifications: Collection>(
        _ notification: TerminalNotification,
        into indexes: inout NotificationIndexes,
        notifications: Notifications
    ) where Notifications.Element == TerminalNotification {
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
        for key in unreadIndexKeys(for: notification) {
            indexes.unreadCountByTabSurface[key, default: 0] += 1
            indexes.unreadByTabSurface.insert(key)
        }

    }

    static func insertNotification<Notifications: Collection>(
        _ notification: TerminalNotification,
        evicting evicted: TerminalNotification,
        into indexes: inout NotificationIndexes,
        notifications: Notifications
    ) where Notifications.Element == TerminalNotification {
        insertNotification(
            notification,
            evicting: [evicted],
            into: &indexes,
            notifications: notifications
        )
    }

    static func insertNotification<Notifications: Collection>(
        _ notification: TerminalNotification,
        evicting evicted: [TerminalNotification],
        into indexes: inout NotificationIndexes,
        notifications: Notifications
    ) where Notifications.Element == TerminalNotification {
        let expectedPreviousCount = notifications.count + evicted.count - 1
        guard indexes.ids.count == expectedPreviousCount,
              !indexes.ids.contains(notification.id) else {
            indexes = buildIndexes(for: notifications)
            return
        }
        for evictedNotification in evicted {
            guard indexes.ids.remove(evictedNotification.id) != nil else {
                indexes = buildIndexes(for: notifications)
                return
            }

            let evictedTabSurfaceKey = TabSurfaceKey(
                tabId: evictedNotification.tabId,
                surfaceId: evictedNotification.surfaceId
            )
            let evictedWasLatestForTab =
                indexes.latestByTabId[evictedNotification.tabId]?.id == evictedNotification.id
            let evictedWasLatestForSurface =
                indexes.latestByTabSurface[evictedTabSurfaceKey]?.id == evictedNotification.id
            if evictedWasLatestForTab {
                indexes.latestByTabId.removeValue(forKey: evictedNotification.tabId)
            }
            if evictedWasLatestForSurface {
                indexes.latestByTabSurface.removeValue(forKey: evictedTabSurfaceKey)
            }
            if !evictedNotification.isRead {
                indexes.unreadCount -= 1
                adjustCount(for: evictedNotification.tabId, by: -1, in: &indexes.unreadCountByTabId)
                for key in unreadIndexKeys(for: evictedNotification) {
                    adjustCount(for: key, by: -1, in: &indexes.unreadCountByTabSurface)
                    if indexes.unreadCountByTabSurface[key] == nil {
                        indexes.unreadByTabSurface.remove(key)
                    }
                }
            }
        }

        insertNotification(notification, into: &indexes, notifications: notifications)
        // This path is only used by append-newest-at-capacity. The evicted row
        // is the oldest retained row, so if it owned the latest slot for its
        // tab or surface there is no replacement row for that key. Avoid a
        // full-feed scan on every capped insertion.
    }

    static func updateReadState(
        from before: TerminalNotification,
        to after: TerminalNotification,
        in indexes: inout NotificationIndexes,
        notifications: [TerminalNotification]
    ) -> Bool {
        guard before.id == after.id,
              before.tabId == after.tabId,
              before.surfaceId == after.surfaceId,
              before.panelId == after.panelId,
              before.isRead != after.isRead,
              indexes.ids.count == notifications.count,
              indexes.ids.contains(after.id) else {
            indexes = buildIndexes(for: notifications)
            return false
        }

        if indexes.latestByTabId[after.tabId]?.id == after.id {
            indexes.latestByTabId[after.tabId] = after
        }
        let tabSurfaceKey = TabSurfaceKey(tabId: after.tabId, surfaceId: after.surfaceId)
        if indexes.latestByTabSurface[tabSurfaceKey]?.id == after.id {
            indexes.latestByTabSurface[tabSurfaceKey] = after
        }

        let delta = after.isRead ? -1 : 1
        indexes.unreadCount += delta
        adjustCount(for: after.tabId, by: delta, in: &indexes.unreadCountByTabId)
        for key in unreadIndexKeys(for: after) {
            adjustCount(for: key, by: delta, in: &indexes.unreadCountByTabSurface)
            if indexes.unreadCountByTabSurface[key] == nil {
                indexes.unreadByTabSurface.remove(key)
            } else {
                indexes.unreadByTabSurface.insert(key)
            }
        }
        return true
    }

    private static func adjustCount<Key: Hashable>(
        for key: Key,
        by delta: Int,
        in counts: inout [Key: Int]
    ) {
        let next = (counts[key] ?? 0) + delta
        if next > 0 {
            counts[key] = next
        } else {
            counts.removeValue(forKey: key)
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
