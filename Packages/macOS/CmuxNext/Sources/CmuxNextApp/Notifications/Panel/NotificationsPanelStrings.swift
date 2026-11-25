import Foundation

/// Text of the notifications panel. Keys live in
/// Resources/NotificationsPanel.xcstrings.
enum NotificationsPanelStrings {
    static var title: String { String(localized: "notificationsPanel.title", defaultValue: "Notifications", table: "NotificationsPanel", bundle: .module) }
    static var markAllRead: String { String(localized: "notificationsPanel.markAllRead", defaultValue: "Mark All Read", table: "NotificationsPanel", bundle: .module) }
    static var clearAll: String { String(localized: "notificationsPanel.clearAll", defaultValue: "Clear All", table: "NotificationsPanel", bundle: .module) }
    static var emptyTitle: String { String(localized: "notificationsPanel.empty.title", defaultValue: "You're all caught up", table: "NotificationsPanel", bundle: .module) }
    static var emptySubtitle: String { String(localized: "notificationsPanel.empty.subtitle", defaultValue: "New activity will appear here.", table: "NotificationsPanel", bundle: .module) }
    static var sourceClosed: String { String(localized: "notificationsPanel.sourceClosed", defaultValue: "The tab that posted this notification has closed.", table: "NotificationsPanel", bundle: .module) }
    static var notificationGone: String { String(localized: "notificationsPanel.notificationGone", defaultValue: "That notification is no longer in the list.", table: "NotificationsPanel", bundle: .module) }
    static var dismiss: String { String(localized: "notificationsPanel.dismiss", defaultValue: "Dismiss", table: "NotificationsPanel", bundle: .module) }
}
