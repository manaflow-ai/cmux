import Foundation

/// Versioned, revisioned on-disk representation of the notification feed.
struct NotificationFeedHistorySnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let revision: Int
    let notifications: [NotificationFeedHistoryRecord]

    init(
        revision: Int,
        notifications: [NotificationFeedHistoryRecord],
        version: Int = Self.currentVersion
    ) {
        self.version = version
        self.revision = revision
        self.notifications = notifications
    }
}
