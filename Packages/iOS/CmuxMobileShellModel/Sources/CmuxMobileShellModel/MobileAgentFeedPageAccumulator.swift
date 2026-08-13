/// Per-Mac paged Feed history retained by the iOS client.
public struct MobileAgentFeedPageAccumulator: Equatable, Sendable {
    /// Latest host revision represented by the accumulator.
    public private(set) var revision: UInt64
    /// Deduplicated retained items in reverse chronological order.
    public private(set) var items: [MobileWorkstreamFeedListItem]
    /// Opaque cursor for this Mac's next older page.
    public private(set) var nextCursor: String?
    /// Whether this Mac retains items before the loaded pages.
    public private(set) var hasMore: Bool
    /// Whether at least one older page has been appended.
    public private(set) var hasLoadedOlder: Bool
    /// Whether paging stopped because the phone retention limit was reached.
    public private(set) var reachedHistoryLimit: Bool

    /// Starts an accumulator from the host's newest page.
    public init(response: MobileWorkstreamFeedListResponse) {
        revision = response.revision
        let merge = Self.merged(response.items)
        items = merge.items
        nextCursor = response.nextCursor
        hasMore = response.hasMore
        hasLoadedOlder = false
        reachedHistoryLimit = false
        applyRetentionBoundary(wasTruncated: merge.wasTruncated)
    }

    /// Merges a refreshed newest page without discarding already loaded history.
    public mutating func applyFirstPage(_ response: MobileWorkstreamFeedListResponse) {
        revision = response.revision
        let merge = Self.merged(response.items + (hasLoadedOlder ? items : []))
        items = merge.items
        if !hasLoadedOlder {
            nextCursor = response.nextCursor
            hasMore = response.hasMore
        }
        applyRetentionBoundary(wasTruncated: merge.wasTruncated)
    }

    /// Appends the next older page and advances this Mac's stable cursor.
    public mutating func append(_ response: MobileWorkstreamFeedListResponse) {
        revision = max(revision, response.revision)
        let merge = Self.merged(items + response.items)
        items = merge.items
        nextCursor = response.nextCursor
        hasMore = response.hasMore
        hasLoadedOlder = true
        applyRetentionBoundary(wasTruncated: merge.wasTruncated)
    }

    private static func merged(
        _ candidates: [MobileWorkstreamFeedListItem]
    ) -> (items: [MobileWorkstreamFeedListItem], wasTruncated: Bool) {
        var newestByID: [MobileWorkstreamFeedListItem.ID: MobileWorkstreamFeedListItem] = [:]
        for item in candidates {
            if let existing = newestByID[item.id], existing.updatedAt >= item.updatedAt { continue }
            newestByID[item.id] = item
        }
        return (
            Array(newestByID.values.sorted(by: precedes).prefix(MobileAgentFeedAggregation.maxItemCount)),
            newestByID.count > MobileAgentFeedAggregation.maxItemCount
        )
    }

    private mutating func applyRetentionBoundary(wasTruncated: Bool) {
        reachedHistoryLimit = reachedHistoryLimit
            || wasTruncated
            || (items.count == MobileAgentFeedAggregation.maxItemCount && hasMore)
        guard reachedHistoryLimit else { return }
        nextCursor = nil
        hasMore = false
    }

    private static func precedes(
        _ lhs: MobileWorkstreamFeedListItem,
        _ rhs: MobileWorkstreamFeedListItem
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
