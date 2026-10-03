public import Foundation

/// A self-contained feed owner for demos, snapshots and tests: seeded items,
/// the owner's lifecycle rules (first answer wins, `feed.closed` for a late
/// answer), and intents committed on the next main-actor turn (no timers).
@MainActor
public final class MockFeedSource: FeedPostingSource {
    private var sink: (@MainActor (FeedSourceEvent) -> Void)?
    private var items: [String: FeedItem]
    private var revision: UInt64
    private let user: String
    private let device: String
    /// Intents whose key is listed here are rejected (tests).
    public var rejectKeys: Set<String> = []
    /// When false, intents wait for `deliverHeld()` (tests).
    public var echoImmediately = true
    private var held: [FeedIntent] = []

    public init(snapshot: FeedSnapshot) {
        items = Dictionary(snapshot.items.map { ($0.id, $0) }) { _, last in last }
        revision = snapshot.revision
        user = snapshot.user
        device = snapshot.device
    }

    /// The demo feed, posted relative to `now`.
    public convenience init(now: Date = Date()) {
        self.init(snapshot: FeedSnapshot(revision: 100, user: "usr_lawrence", device: "MacBook Pro", items: MockFeedSeed.items(now: now)))
    }

    public func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.sink = sink
        sink(.connection(.connected))
        sink(.snapshot(FeedSnapshot(revision: revision, user: user, device: device, items: Array(items.values))))
    }

    public func stop() {
        sink = nil
    }

    public func send(_ intent: FeedIntent) {
        if echoImmediately {
            Task { @MainActor [weak self] in self?.commit(intent) }
        } else {
            held.append(intent)
        }
    }

    public func deliverHeld() {
        let intents = held
        held.removeAll()
        for intent in intents { commit(intent) }
    }

    public func disconnect() {
        sink?(.connection(.disconnected("Feed owner unreachable")))
    }

    /// Another device answers first (an iPhone push action): one event from
    /// another principal's request, no `tx` of this client.
    public func answerElsewhere(_ id: String, value: FeedAnswerValue, device: String, at: Date) {
        guard var item = items[id], item.isOpenRequest else { return }
        item.state = .answered
        item.answer = FeedAnswerRecord(value: value, by: user, device: device, at: at)
        item.closedAt = at
        item.readAt = item.readAt ?? at
        publish([item], tx: nil)
    }

    /// The poster posts or updates an item.
    public func post(_ item: FeedItem) {
        if let key = item.dedupeKey,
           let existing = items.values.first(where: { $0.dedupeKey == key && $0.state == .open && $0.archivedAt == nil }) {
            if item.isRequest { return }
            var updated = item
            updated.id = existing.id
            updated.count = existing.count + 1
            updated.revision = existing.revision
            updated.createdAt = existing.createdAt
            updated.readAt = nil
            publish([updated], tx: nil)
            return
        }
        publish([item], tx: nil)
    }

    private func commit(_ intent: FeedIntent) {
        guard let sink else { return }
        if rejectKeys.contains(intent.key) {
            sink(.settled(key: intent.key, reject: .other("rejected by the owner")))
            return
        }
        // The owner's lifecycle rule: an answer or decline to a closed
        // request is refused with the item (`feed.closed`).
        switch intent.kind {
        case let .answer(id, _), let .decline(id):
            if let item = items[id], item.state.isClosed {
                sink(.settled(key: intent.key, reject: .closed(item)))
                return
            }
        default:
            break
        }
        var next = items
        intent.apply(to: &next, user: user, device: device)
        let changed = next.values.filter { items[$0.id] != $0 }.sorted { $0.id < $1.id }
        if !changed.isEmpty { publish(changed, tx: intent.key) }
        sink(.settled(key: intent.key, reject: nil))
    }

    private func publish(_ changed: [FeedItem], tx: String?) {
        revision += 1
        var stamped: [FeedItem] = []
        for var item in changed {
            item.revision = (items[item.id]?.revision ?? 0) + 1
            items[item.id] = item
            stamped.append(item)
        }
        sink?(.event(FeedEvent(revision: revision, tx: tx, change: .items(stamped))))
    }
}
