/// Stable and historical Feed rows prepared outside SwiftUI rendering.
struct FeedActivitySnapshotGroups: Equatable {
    let stable: [FeedItemSnapshot]
    let history: [FeedItemSnapshot]
    let ordered: [FeedItemSnapshot]

    init(stable: [FeedItemSnapshot], history: [FeedItemSnapshot]) {
        self.stable = stable
        self.history = history
        self.ordered = stable + history
    }
}
