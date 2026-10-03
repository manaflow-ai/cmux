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
    private var primarySnapshot: FeedSnapshot?
    private var localSnapshot: FeedSnapshot?
    private var splitIntents: [String: Int] = [:]
    private var splitRejects: [String: FeedReject] = [:]

    public init(primary: any FeedSource, local: MockFeedSource? = nil) {
        self.primary = primary
        self.local = local ?? MockFeedSource(snapshot: FeedSnapshot(revision: 0, user: "", device: "Mac", items: []))
    }

    public func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.sink = sink
        primary.start { [weak self] event in
            guard let self else { return }
            switch event {
            case let .snapshot(snapshot):
                self.primarySnapshot = snapshot
                self.emitMergedSnapshot()
            case let .event(event):
                let tx = event.tx.flatMap { self.splitIntents[$0] == nil ? $0 : nil }
                self.sink?(.event(FeedEvent(revision: event.revision, tx: tx, change: event.change)))
            case .connection:
                self.sink?(event)
            case let .settled(key, reject):
                self.settled(key: key, reject: reject)
            }
        }
        // The local source's connection and empty snapshot must not replace
        // the primary owner's authoritative state in FeedModel.
        local.start { [weak self] event in
            guard let self else { return }
            switch event {
            case let .snapshot(snapshot):
                self.localItemIDs.formUnion(snapshot.items.map(\.id))
                self.localSnapshot = snapshot
                self.emitMergedSnapshot()
            case let .event(event):
                switch event.change {
                case let .items(items): self.localItemIDs.formUnion(items.map(\.id))
                case let .remove(ids): self.localItemIDs.subtract(ids)
                }
                let tx = event.tx.flatMap { self.splitIntents[$0] == nil ? $0 : nil }
                self.sink?(.event(FeedEvent(revision: event.revision, tx: tx, change: event.change)))
            case .connection:
                break
            case let .settled(key, reject):
                self.settled(key: key, reject: reject)
            }
        }
    }

    public func send(_ intent: FeedIntent) {
        switch intent.kind {
        case let .read(items), let .archive(items), let .snooze(items, _):
            let local = items.filter { localItemIDs.contains($0) }
            let remote = items.filter { !localItemIDs.contains($0) }
            if !local.isEmpty && !remote.isEmpty { splitIntents[intent.key] = 2 }
            if !local.isEmpty { self.local.send(intent.withItems(local)) }
            if !remote.isEmpty { primary.send(intent.withItems(remote)) }
        case let .answer(item, _), let .decline(item):
            if localItemIDs.contains(item) { local.send(intent) } else { primary.send(intent) }
        case .markAllRead:
            // This intent spans both owners. Both reducers receive the same
            // idempotency key and independently settle their owned items.
            splitIntents[intent.key] = 2
            local.send(intent)
            primary.send(intent)
        }
    }

    public func stop() {
        primary.stop()
        local.stop()
        localItemIDs.removeAll()
        primarySnapshot = nil
        localSnapshot = nil
        splitIntents.removeAll()
        splitRejects.removeAll()
        sink = nil
    }

    /// Posts through the local owner so the item keeps its integration poster
    /// kind and never travels through a signed-in cloud session principal.
    public func post(_ item: FeedItem) {
        localItemIDs.insert(item.id)
        local.post(item)
    }
}

private extension LocalFeedSourceAdapter {
    func emitMergedSnapshot() {
        guard let primarySnapshot, let sink else { return }
        let localItems = localSnapshot?.items ?? []
        let merged = Dictionary((primarySnapshot.items + localItems).map { ($0.id, $0) }) { _, local in local }
        sink(.snapshot(FeedSnapshot(revision: max(primarySnapshot.revision, localSnapshot?.revision ?? 0),
                                    user: primarySnapshot.user, device: primarySnapshot.device,
                                    items: Array(merged.values))))
    }

    func settled(key: String, reject: FeedReject?) {
        guard let remaining = splitIntents[key] else {
            sink?(.settled(key: key, reject: reject))
            return
        }
        if let reject { splitRejects[key] = reject }
        if remaining == 1 {
            splitIntents[key] = nil
            sink?(.settled(key: key, reject: splitRejects.removeValue(forKey: key)))
        } else {
            splitIntents[key] = remaining - 1
        }
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
