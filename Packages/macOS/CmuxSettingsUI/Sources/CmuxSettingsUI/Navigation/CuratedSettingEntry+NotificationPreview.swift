import CmuxSettings
import Foundation

extension Array where Element == CuratedSettingEntry {
    /// Search entries for the sidebar notification-preview read behavior
    /// (`sidebar.clearReadNotificationMessage`), appended to ``cmuxDefault(catalog:)``.
    static var sidebarNotificationPreviewEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .sidebarAppearance,
                id: "clear-read-notification-message",
                title: String(localized: "settings.app.clearReadNotificationMessage", defaultValue: "Clear Notification Message Once Read"),
                synonyms: "sidebar.clearReadNotificationMessage notification message preview read unread clear dismiss keep latest sidebar"
            ),
        ]
    }
}
