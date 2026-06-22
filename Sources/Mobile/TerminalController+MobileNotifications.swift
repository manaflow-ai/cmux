import Foundation

extension TerminalController {
    /// `mobile.notifications.list`: recent notification feed mirrored by iOS.
    func v2MobileNotificationsList(params _: [String: Any]) -> V2CallResult {
        guard let store = AppDelegate.shared?.notificationStore else {
            return .ok(["notifications": []])
        }
        let hideContent = UserDefaults.standard.bool(forKey: PhonePushSettings.hideContentKey)
        let recent = Self.mobileRecentNotifications(store.notifications)
        let items: [[String: Any]] = recent.map { notification in
            Self.mobileNotificationListItem(notification, hideContent: hideContent)
        }
        return .ok(["notifications": items])
    }

    /// Recent-notification window kept in sync with the iOS feed store.
    nonisolated static let mobileNotificationRecentLimit = 200

    /// Select the recent visible feed window by notification timestamp.
    ///
    /// `TerminalNotificationStore.notifications` is presentation ordered, not
    /// strictly chronological: read-state actions can move unread items for menu
    /// behavior. Keep the mobile feed independent from that ordering by scanning
    /// the store once and retaining only the bounded top-N chronological window.
    nonisolated static func mobileRecentNotifications(
        _ notifications: [TerminalNotification],
        limit: Int = mobileNotificationRecentLimit
    ) -> [TerminalNotification] {
        guard limit > 0 else { return [] }
        var recent: [TerminalNotification] = []
        recent.reserveCapacity(min(limit, notifications.count))

        for notification in notifications {
            let insertionIndex = recent.firstIndex { isMobileNotificationMoreRecent(notification, than: $0) } ?? recent.endIndex
            if insertionIndex < limit {
                recent.insert(notification, at: insertionIndex)
                if recent.count > limit {
                    recent.removeLast()
                }
            } else if recent.count < limit {
                recent.append(notification)
            }
        }

        return recent
    }

    private nonisolated static func isMobileNotificationMoreRecent(
        _ lhs: TerminalNotification,
        than rhs: TerminalNotification
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    nonisolated static func mobileNotificationListItem(_ notification: TerminalNotification, hideContent: Bool) -> [String: Any] {
        let content = mobileNotificationFeedContent(notification, hideContent: hideContent)
        let surfaceID: Any = notification.surfaceId?.uuidString ?? NSNull()
        return [
            "id": notification.id.uuidString,
            "workspace_id": notification.tabId.uuidString,
            "surface_id": surfaceID,
            "title": content.title,
            "subtitle": content.subtitle,
            "body": content.body,
            "created_at": notification.createdAt.timeIntervalSince1970,
            "is_read": notification.isRead,
            "is_content_hidden": hideContent,
        ]
    }

    nonisolated static func mobileNotificationFeedContent(
        _ notification: TerminalNotification,
        hideContent: Bool
    ) -> (title: String, subtitle: String, body: String) {
        guard !hideContent else { return ("", "", "") }
        let content = PhonePushSettings.contentFields(
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            hideContent: hideContent
        )
        return (
            title: mobilePreviewSanitize(content.title) ?? "",
            subtitle: mobilePreviewSanitize(content.subtitle) ?? "",
            body: mobilePreviewSanitize(content.body) ?? ""
        )
    }
}
