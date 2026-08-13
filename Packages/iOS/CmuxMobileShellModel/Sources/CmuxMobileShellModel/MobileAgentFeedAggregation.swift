/// Deterministic bounded aggregation for workstream snapshots from every Mac.
public struct MobileAgentFeedAggregation: Sendable {
    public static let maxItemCount = 2_000

    public init() {}

    public func items(from snapshots: [[MobileAgentFeedItem]]) -> [MobileAgentFeedItem] {
        var newestByID: [MobileAgentFeedItemID: MobileAgentFeedItem] = [:]
        newestByID.reserveCapacity(Self.maxItemCount)
        for item in snapshots.joined() {
            if let existing = newestByID[item.id],
               item.wire.updatedAt <= existing.wire.updatedAt { continue }
            newestByID[item.id] = item
        }
        return Array(newestByID.values.sorted(by: Self.precedes).prefix(Self.maxItemCount))
    }

    /// `createdAt` owns position; status-only `updatedAt` never moves a card.
    public static func precedes(_ lhs: MobileAgentFeedItem, _ rhs: MobileAgentFeedItem) -> Bool {
        if lhs.wire.createdAt != rhs.wire.createdAt {
            return lhs.wire.createdAt > rhs.wire.createdAt
        }
        return lhs.id < rhs.id
    }
}
