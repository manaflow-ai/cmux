import Foundation

/// Size bounds for the persisted Vault history event log.
///
/// The store enforces these on every append and load so the on-disk file and
/// the in-memory buffer are bounded by construction — there is no code path
/// that scans an unbounded file (cf. issue #4536).
struct VaultHistoryRetentionPolicy: Sendable {
    /// Maximum events kept in memory and rewritten to disk on compaction.
    let maxStoredEvents: Int
    /// File size that triggers a compacting rewrite on the next append.
    let maxFileBytes: Int
    /// Byte budget for the tail read performed when loading persisted events.
    let maxLoadBytes: Int

    static let `default` = VaultHistoryRetentionPolicy(
        maxStoredEvents: 2000,
        maxFileBytes: 4 * 1024 * 1024,
        maxLoadBytes: 2 * 1024 * 1024
    )

    init(maxStoredEvents: Int, maxFileBytes: Int, maxLoadBytes: Int) {
        self.maxStoredEvents = max(1, maxStoredEvents)
        self.maxFileBytes = max(1024, maxFileBytes)
        self.maxLoadBytes = max(1024, maxLoadBytes)
    }
}
