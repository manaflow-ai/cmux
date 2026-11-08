import Foundation

enum NotificationFeedHistoryInsertionChange: Sendable {
    case none
    case insertedNew(UUID)
    case replacedExisting
}
