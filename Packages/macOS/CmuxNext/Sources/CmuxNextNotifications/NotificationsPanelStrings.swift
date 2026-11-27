import Foundation

/// Text of the notifications panel. Keys live in
/// Resources/NotificationsPanelList.xcstrings.
package struct NotificationsPanelStrings {
    package init() {}
    package static var title: String { String(localized: "notificationsPanel.title", defaultValue: "Notifications", table: "NotificationsPanelList", bundle: .localizedModule) }
    package static var markAllRead: String { String(localized: "notificationsPanel.markAllRead", defaultValue: "Mark All Read", table: "NotificationsPanelList", bundle: .localizedModule) }
    package static var clearAll: String { String(localized: "notificationsPanel.clearAll", defaultValue: "Clear All", table: "NotificationsPanelList", bundle: .localizedModule) }
    package static var emptyTitle: String { String(localized: "notificationsPanel.empty.title", defaultValue: "You're all caught up", table: "NotificationsPanelList", bundle: .localizedModule) }
    package static var emptySubtitle: String { String(localized: "notificationsPanel.empty.subtitle", defaultValue: "New activity will appear here.", table: "NotificationsPanelList", bundle: .localizedModule) }
    package static var sourceClosed: String { String(localized: "notificationsPanel.sourceClosed", defaultValue: "The tab that posted this notification has closed.", table: "NotificationsPanelList", bundle: .localizedModule) }
    package static var notificationGone: String { String(localized: "notificationsPanel.notificationGone", defaultValue: "That notification is no longer in the list.", table: "NotificationsPanelList", bundle: .localizedModule) }
    package static var dismiss: String { String(localized: "notificationsPanel.dismiss", defaultValue: "Dismiss", table: "NotificationsPanelList", bundle: .localizedModule) }
}
