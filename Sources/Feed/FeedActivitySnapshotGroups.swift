/// Stable and historical Feed rows prepared outside SwiftUI rendering.
struct FeedActivitySnapshotGroups: Equatable {
    let stable: [FeedItemSnapshot]
    let history: [FeedItemSnapshot]

    var ordered: [FeedItemSnapshot] { stable + history }
}
