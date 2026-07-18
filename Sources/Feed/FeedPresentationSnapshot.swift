/// Immutable presentation data consumed by the Feed list.
struct FeedPresentationSnapshot: Equatable {
    static let empty = FeedPresentationSnapshot(actionable: [])

    let actionable: [FeedItemSnapshot]
}
