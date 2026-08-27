import Foundation

/// Stored value for one tracked-changes snapshot cache entry.
struct GitTrackedChangesSnapshotCacheEntry: Sendable {
    let snapshot: GitTrackedChangesSnapshot
}
