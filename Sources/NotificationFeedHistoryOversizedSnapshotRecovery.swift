import Foundation

struct NotificationFeedHistoryOversizedSnapshotRecovery: Sendable {
    let snapshot: NotificationFeedHistorySnapshot
    let shouldRetainQuarantineBackup: Bool
}
