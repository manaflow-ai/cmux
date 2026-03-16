//
//  NotificationMenu.swift
//  cmux
//
//  Created by Gale Williams on 3/16/26.
//

import Foundation

// MARK: - NotificationMenuItemPayload

final class NotificationMenuItemPayload: NSObject {
    // MARK: Properties

    let notification: TerminalNotification

    // MARK: Lifecycle

    init(notification: TerminalNotification) {
        self.notification = notification
        super.init()
    }
}

// MARK: - NotificationMenuSnapshot

struct NotificationMenuSnapshot {
    // MARK: Properties

    let unreadCount: Int
    let hasNotifications: Bool
    let recentNotifications: [TerminalNotification]

    // MARK: Computed Properties

    var hasUnreadNotifications: Bool {
        unreadCount > 0
    }

    var stateHintTitle: String {
        NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: unreadCount)
    }
}

// MARK: - NotificationMenuSnapshotBuilder

enum NotificationMenuSnapshotBuilder {
    // MARK: Static Properties

    static let defaultInlineNotificationLimit = 6

    // MARK: Static Functions

    static func make(
        notifications: [TerminalNotification],
        maxInlineNotificationItems: Int = defaultInlineNotificationLimit
    ) -> NotificationMenuSnapshot {
        let unreadCount = notifications.reduce(into: 0) { count, notification in
            if !notification.isRead {
                count += 1
            }
        }

        let inlineLimit = max(0, maxInlineNotificationItems)
        return NotificationMenuSnapshot(
            unreadCount: unreadCount,
            hasNotifications: !notifications.isEmpty,
            recentNotifications: Array(notifications.prefix(inlineLimit))
        )
    }

    static func stateHintTitle(unreadCount: Int) -> String {
        switch unreadCount {
            case 0:
                String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications")
            case 1:
                String(localized: "statusMenu.unreadCount.one", defaultValue: "1 unread notification")
            default:
                String(localized: "statusMenu.unreadCount.other", defaultValue: "\(unreadCount) unread notifications")
        }
    }
}
