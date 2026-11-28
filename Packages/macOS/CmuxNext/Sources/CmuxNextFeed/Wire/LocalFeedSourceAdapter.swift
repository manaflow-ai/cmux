import Foundation

/// Combines an optional cloud owner with the local owner used by GitHub today.
///
/// The local owner is an in-memory fallback until the daemon implements the
/// same `FeedPostingSource` seam. It remains authoritative for its own items,
/// even when cloud authentication is absent or the cloud socket is down.
@MainActor
public final class LocalFeedSourceAdapter: FeedPostingSource {
    private let primary: (any FeedSource)?
    private let local: any FeedPostingSource
    private var sink: (@MainActor (FeedSourceEvent) -> Void)?
    private var localItemIDs: Set<String> = []
    private var primarySnapshot: FeedSnapshot?
    private var localSnapshot: FeedSnapshot?
    private var primaryConnected = false
    private var localConnected = false
    private var splitIntents: [String: Int] = [:]
    private var splitRejects: [String: FeedReject] = [:]
    private var primaryHandler: (@MainActor (FeedSourceEvent) -> Void)?

    public init(primary: (any FeedSource)? = nil, local: (any FeedPostingSource)? = nil) {
        self.primary = primary
        self.local = local ?? InMemoryFeedSource(snapshot: FeedSnapshot(revision: 0, user: "", device: "Mac", items: []))
    }

    public func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.sink = sink
        let primaryHandler: @MainActor (FeedSourceEvent) -> Void = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .snapshot(snapshot):
                self.primarySnapshot = snapshot
                self.emitMergedSnapshot()
            case let .event(event):
                let tx = event.tx.flatMap { self.splitIntents[$0] == nil ? $0 : nil }
                self.sink?(.event(FeedEvent(revision: event.revision, tx: tx, change: event.change)))
            case .connection:
                if case .connected = event.connectionValue { self.primaryConnected = true }
                if case .disconnected = event.connectionValue { self.primaryConnected = false }
                self.emitConnection()
            case let .settled(key, reject):
                self.settled(key: key, reject: reject)
            }
        }
        self.primaryHandler = primaryHandler
        primary?.start(primaryHandler)
        local.start { [weak self] event in
            guard let self else { return }
            switch event {
            case let .snapshot(snapshot):
                self.localItemIDs.formUnion(snapshot.items.map(\.id))
                self.localSnapshot = snapshot
                self.emitMergedSnapshot()
                self.localConnected = true
                self.emitConnection()
            case let .event(event):
                switch event.change {
                case let .items(items): self.localItemIDs.formUnion(items.map(\.id))
                case let .remove(ids): self.localItemIDs.subtract(ids)
                }
                let tx = event.tx.flatMap { self.splitIntents[$0] == nil ? $0 : nil }
                self.sink?(.event(FeedEvent(revision: event.revision, tx: tx, change: event.change)))
            case .connection:
                if case .connected = event.connectionValue { self.localConnected = true }
                if case .disconnected = event.connectionValue { self.localConnected = false }
                self.emitConnection()
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
            if !remote.isEmpty {
                if primaryConnected {
                    primary?.send(intent.withItems(remote))
                } else {
                    settled(key: intent.key, reject: .disconnected)
                }
            }
        case let .answer(item, _), let .decline(item):
            if localItemIDs.contains(item) {
                local.send(intent)
            } else if primaryConnected {
                primary?.send(intent)
            } else {
                settled(key: intent.key, reject: .disconnected)
            }
        case .markAllRead:
            // This intent spans both owners. Both reducers receive the same
            // idempotency key and independently settle their owned items.
            if primaryConnected { splitIntents[intent.key] = 2 }
            local.send(intent)
            if primaryConnected {
                primary?.send(intent)
            }
        }
    }

    public func stop() {
        primary?.stop()
        local.stop()
        localItemIDs.removeAll()
        primarySnapshot = nil
        localSnapshot = nil
        splitIntents.removeAll()
        splitRejects.removeAll()
        primaryConnected = false
        localConnected = false
        sink = nil
    }

    /// Restarts only the cloud leg after authentication changes.
    public func reconnectPrimary() {
        guard let primary, let primaryHandler else { return }
        primary.start(primaryHandler)
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
        guard let sink else { return }
        guard let primarySnapshot else {
            guard let localSnapshot else { return }
            sink(.snapshot(localSnapshot))
            return
        }
        let localItems = localSnapshot?.items ?? []
        let merged = Dictionary((primarySnapshot.items + localItems).map { ($0.id, $0) }) { _, local in local }
        sink(.snapshot(FeedSnapshot(revision: max(primarySnapshot.revision, localSnapshot?.revision ?? 0),
                                    user: primarySnapshot.user, device: primarySnapshot.device,
                                    items: Array(merged.values))))
    }

    func emitConnection() {
        guard let sink else { return }
        if localConnected || primaryConnected {
            sink(.connection(.connected))
        } else if primary != nil {
            sink(.connection(.disconnected("Feed owners unreachable")))
        }
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

private extension FeedSourceEvent {
    var connectionValue: FeedConnection {
        if case let .connection(value) = self { return value }
        return .disconnected("not a connection event")
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
