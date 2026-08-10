import Foundation

nonisolated enum NotificationFeedHistoryInsertionChange: Sendable {
    case none
    case insertedNew(UUID)
    case replacedExisting
}
