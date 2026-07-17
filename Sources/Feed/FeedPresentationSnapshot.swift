/// Immutable presentation data consumed by the Feed list.
struct FeedPresentationSnapshot: Equatable {
    static let empty = FeedPresentationSnapshot(
        actionable: [],
        activity: FeedActivitySnapshotGroups(stable: [], history: [])
    )

    let actionable: [FeedItemSnapshot]
    let activity: FeedActivitySnapshotGroups
}
