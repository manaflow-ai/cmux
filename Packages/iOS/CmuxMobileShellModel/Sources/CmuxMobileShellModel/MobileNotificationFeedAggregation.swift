import Foundation

/// Produces one deterministic cross-Mac feed from per-Mac notification snapshots.
public struct MobileNotificationFeedAggregation: Sendable {
    /// Creates a stateless feed aggregator.
    public init() {}

    /// Deduplicates composite identities and orders notifications newest first.
    ///
    /// Equal timestamps use ``MobileNotificationFeedItemID`` as a deterministic
    /// tie-breaker, so list order never flickers across repeated refreshes.
    /// - Parameter snapshots: Per-Mac item arrays.
    /// - Returns: A stable, reverse-chronological cross-Mac feed.
    public func items(from snapshots: [[MobileNotificationFeedItem]]) -> [MobileNotificationFeedItem] {
        var newestByIdentity: [MobileNotificationFeedItemID: MobileNotificationFeedItem] = [:]
        for item in snapshots.joined() {
            if let existing = newestByIdentity[item.id], existing.createdAt > item.createdAt {
                continue
            }
            newestByIdentity[item.id] = item
        }
        return newestByIdentity.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }
}
