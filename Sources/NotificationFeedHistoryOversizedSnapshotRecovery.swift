import Foundation

nonisolated struct NotificationFeedHistoryOversizedSnapshotRecovery: Sendable {
    let snapshot: NotificationFeedHistorySnapshot
    let shouldRetainQuarantineBackup: Bool
}
