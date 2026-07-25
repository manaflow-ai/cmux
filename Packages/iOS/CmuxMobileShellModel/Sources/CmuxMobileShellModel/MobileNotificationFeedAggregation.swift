import Foundation

/// One per-Mac notification source plus the connection status to project onto
/// retained rows during aggregation.
public struct MobileNotificationFeedSourceSnapshot: Sendable {
    public let items: [MobileNotificationFeedItem]
    public let connectionStatus: MobileMacConnectionStatus?

    public init(
        items: [MobileNotificationFeedItem],
        connectionStatus: MobileMacConnectionStatus? = nil
    ) {
        self.items = items
        self.connectionStatus = connectionStatus
    }
}

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
    /// - Parameter snapshots: Per-Mac item arrays, already ordered newest first.
    /// - Returns: A stable, reverse-chronological cross-Mac feed.
    public func items(from snapshots: [[MobileNotificationFeedItem]]) -> [MobileNotificationFeedItem] {
        items(from: snapshots.map { MobileNotificationFeedSourceSnapshot(items: $0) })
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

        var frontier = CandidateHeap()
        for (sourceIndex, snapshot) in snapshots.enumerated() {
            guard let item = snapshot.items.first else { continue }
            frontier.insert(Candidate(
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
                frontier.insert(Candidate(
                    item: snapshot.items[nextIndex],
                    sourceIndex: candidate.sourceIndex,
                    itemIndex: nextIndex,
                    connectionStatus: snapshot.connectionStatus
                ))
            }
        }

        return result
    }

    private struct Candidate: Sendable {
        var item: MobileNotificationFeedItem
        var sourceIndex: Int
        var itemIndex: Int
        var connectionStatus: MobileMacConnectionStatus?
    }

    private struct CandidateHeap: Sendable {
        private var storage: [Candidate] = []

        mutating func insert(_ candidate: Candidate) {
            storage.append(candidate)
            siftUp(from: storage.count - 1)
        }

        mutating func pop() -> Candidate? {
            guard !storage.isEmpty else { return nil }
            guard storage.count > 1 else { return storage.removeLast() }
            let candidate = storage[0]
            storage[0] = storage.removeLast()
            siftDown(from: 0)
            return candidate
        }

        private mutating func siftUp(from startIndex: Int) {
            var child = startIndex
            while child > 0 {
                let parent = (child - 1) / 2
                guard candidatePrecedes(storage[child], storage[parent]) else { return }
                storage.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from startIndex: Int) {
            var parent = startIndex
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var candidate = parent
                if left < storage.count, candidatePrecedes(storage[left], storage[candidate]) {
                    candidate = left
                }
                if right < storage.count, candidatePrecedes(storage[right], storage[candidate]) {
                    candidate = right
                }
                guard candidate != parent else { return }
                storage.swapAt(parent, candidate)
                parent = candidate
            }
        }

        private func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.item.createdAt != rhs.item.createdAt {
                return lhs.item.createdAt > rhs.item.createdAt
            }
            if lhs.item.id != rhs.item.id {
                return lhs.item.id < rhs.item.id
            }
            if lhs.sourceIndex != rhs.sourceIndex {
                return lhs.sourceIndex < rhs.sourceIndex
            }
            return lhs.itemIndex < rhs.itemIndex
        }
    }
}
