import Foundation

/// Produces one deterministic cross-Mac feed from per-Mac notification snapshots.
public struct MobileNotificationFeedAggregation: Sendable {
    /// Upper bound for retained notification-feed rows on the phone.
    ///
    /// The Mac keeps the same total history cap, but this defensive cap keeps
    /// newer phones bounded when paired with older Macs that only capped read
    /// history and could return an unbounded unread feed.
    public static let maxItemCount = 2_000

    /// Creates a stateless feed aggregator.
    public init() {}

    /// Deduplicates composite identities and orders notifications newest first.
    ///
    /// Equal timestamps use ``MobileNotificationFeedItemID`` as a deterministic
    /// tie-breaker, so list order never flickers across repeated refreshes.
    /// - Parameter snapshots: Per-Mac item arrays in any order.
    /// - Returns: A stable, reverse-chronological cross-Mac feed.
    public func items(from snapshots: [[MobileNotificationFeedItem]]) -> [MobileNotificationFeedItem] {
        guard Self.maxItemCount > 0 else { return [] }

        var newestByIdentity: [MobileNotificationFeedItemID: MobileNotificationFeedItem] = [:]
        newestByIdentity.reserveCapacity(min(
            Self.maxItemCount,
            snapshots.reduce(0) { partialResult, items in
                partialResult + items.count
            }
        ))

        for item in snapshots.joined() {
            if let existing = newestByIdentity[item.id],
               !mobileNotificationFeedItemPrecedes(item, existing) {
                continue
            }
            newestByIdentity[item.id] = item
        }

        let sorted = newestByIdentity.values.sorted(by: mobileNotificationFeedItemPrecedes)
        guard sorted.count > Self.maxItemCount else { return sorted }
        return Array(sorted.prefix(Self.maxItemCount))
    }

    /// Lazily merges newest-first per-Mac snapshots and applies optional
    /// connection-status projection only to rows retained by the global cap.
    ///
    /// This keeps refresh and read-state updates bounded by the phone feed size
    /// instead of materializing and sorting every retained row from every Mac.
    /// - Parameter snapshots: Per-Mac sources, each ordered newest first.
    /// - Returns: A stable, reverse-chronological cross-Mac feed.
    public func items(
        from snapshots: [MobileNotificationFeedSourceSnapshot]
    ) -> [MobileNotificationFeedItem] {
        guard Self.maxItemCount > 0 else { return [] }

        var frontier = MobileNotificationFeedAggregationCandidateHeap()
        for (sourceIndex, snapshot) in snapshots.enumerated() {
            guard let item = snapshot.items.first else { continue }
            frontier.insert(MobileNotificationFeedAggregationCandidate(
                item: item,
                sourceIndex: sourceIndex,
                itemIndex: 0,
                connectionStatus: snapshot.connectionStatus
            ))
        }

        var result: [MobileNotificationFeedItem] = []
        result.reserveCapacity(Self.maxItemCount)
        var emittedIDs = Set<MobileNotificationFeedItemID>()
        emittedIDs.reserveCapacity(Self.maxItemCount)

        while result.count < Self.maxItemCount,
              let candidate = frontier.pop() {
            if emittedIDs.insert(candidate.item.id).inserted {
                if let connectionStatus = candidate.connectionStatus {
                    result.append(candidate.item.updating(connectionStatus: connectionStatus))
                } else {
                    result.append(candidate.item)
                }
            }

            let nextIndex = candidate.itemIndex + 1
            let snapshot = snapshots[candidate.sourceIndex]
            if nextIndex < snapshot.items.count {
                frontier.insert(MobileNotificationFeedAggregationCandidate(
                    item: snapshot.items[nextIndex],
                    sourceIndex: candidate.sourceIndex,
                    itemIndex: nextIndex,
                    connectionStatus: snapshot.connectionStatus
                ))
            }
        }

        return result
    }
}

func mobileNotificationFeedItemPrecedes(
    _ lhs: MobileNotificationFeedItem,
    _ rhs: MobileNotificationFeedItem
) -> Bool {
    if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
    }
    return lhs.id < rhs.id
}
