import Foundation

nonisolated struct NotificationFeedHistorySnapshotHeader: Sendable {
    var version: Int?
    var revision: Int?

    var isComplete: Bool {
        version != nil && revision != nil
    }
}
