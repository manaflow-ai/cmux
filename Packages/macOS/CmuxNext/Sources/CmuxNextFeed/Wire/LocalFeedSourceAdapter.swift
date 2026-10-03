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
    private var localItemIDs: Set<String> = []

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
            guard let self else { return }
            switch event {
            case let .snapshot(snapshot):
                self.localItemIDs.formUnion(snapshot.items.map(\.id))
                self.sink?(event)
            case let .event(event):
                switch event.change {
                case let .items(items): self.localItemIDs.formUnion(items.map(\.id))
                case let .remove(ids): self.localItemIDs.subtract(ids)
                }
                self.sink?(.event(event))
            case .connection, .settled:
                // The cloud owner remains authoritative for connection and
                // settle state. Local events are routed through the same
                // FeedModel mirror without replacing that state.
                break
            }
        }
    }

    public func send(_ intent: FeedIntent) {
        switch intent.kind {
        case let .read(items), let .archive(items), let .snooze(items, _):
            let local = items.filter { localItemIDs.contains($0) }
            let remote = items.filter { !localItemIDs.contains($0) }
            if !local.isEmpty { self.local.send(intent.withItems(local)) }
            if !remote.isEmpty { primary.send(intent.withItems(remote)) }
        case let .answer(item, _), let .decline(item):
            if localItemIDs.contains(item) { local.send(intent) } else { primary.send(intent) }
        case .markAllRead:
            // This intent spans both owners. Both reducers receive the same
            // idempotency key and independently settle their owned items.
            local.send(intent)
            primary.send(intent)
        }
    }

    public func stop() {
        primary.stop()
        local.stop()
        localItemIDs.removeAll()
        sink = nil
    }

    /// Posts through the local owner so the item keeps its integration poster
    /// kind and never travels through a signed-in cloud session principal.
    public func post(_ item: FeedItem) {
        localItemIDs.insert(item.id)
        local.post(item)
    }
}

private extension FeedIntent {
    func withItems(_ items: [String]) -> FeedIntent {
        let kind: FeedIntentKind
        switch self.kind {
        case .read: kind = .read(items: items)
        case .archive: kind = .archive(items: items)
        case let .snooze(_, until): kind = .snooze(items: items, until: until)
        default: return self
        }
        return FeedIntent(key: key, kind: kind, at: at)
    }
}
