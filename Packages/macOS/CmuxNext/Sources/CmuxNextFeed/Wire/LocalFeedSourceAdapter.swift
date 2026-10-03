import Foundation

/// Bridges a real owner with the local feed owner seam used by GitHub today.
/// The primary owner remains authoritative for user intents and connection
/// state; the empty local owner contributes only its committed integration
/// events. The daemon local owner can replace this adapter without changing
/// `GitHubFeedSource` or `FeedModel`.
@MainActor
public final class LocalFeedSourceAdapter: FeedPostingSource {
    private let primary: any FeedSource
    private let local: MockFeedSource
    private var sink: (@MainActor (FeedSourceEvent) -> Void)?

    public init(primary: any FeedSource, local: MockFeedSource? = nil) {
        self.primary = primary
        self.local = local ?? MockFeedSource(snapshot: FeedSnapshot(revision: 0, user: "", device: "Mac", items: []))
    }

    public func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.sink = sink
        primary.start { [weak self] event in self?.sink?(event) }
        // The local source's connection and empty snapshot must not replace
        // the primary owner's authoritative state in FeedModel.
        local.start { [weak self] event in
            guard case .event = event else { return }
            self?.sink?(event)
        }
    }

    public func send(_ intent: FeedIntent) {
        primary.send(intent)
    }

    public func stop() {
        primary.stop()
        local.stop()
        sink = nil
    }

    /// Posts through the local owner so the item keeps its integration poster
    /// kind and never travels through a signed-in cloud session principal.
    public func post(_ item: FeedItem) {
        local.post(item)
    }
}
