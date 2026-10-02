public import Foundation
public import Observation

/// The client's projection of one user's feed: a confirmed mirror written
/// only by owner data (events, snapshots, the item in a `feed.closed`
/// reject), plus one ordered intent log. Visible state is mirror + pending
/// intents; an intent leaves the log on its echo or its settle line
/// (OWNERSHIP-PRINCIPLES "Clients are projections").
@Observable
@MainActor
public final class FeedModel {
    public private(set) var connection: FeedConnection = .connecting
    /// Owner-confirmed items by id (never written by intents).
    public private(set) var confirmed: [String: FeedItem] = [:]
    /// Pending intents in send order.
    public private(set) var pending: [FeedIntent] = []
    /// The last refusal, for the panel's notice; cleared on the next send.
    public private(set) var lastReject: FeedReject?
    public private(set) var revision: UInt64 = 0
    public private(set) var user = ""
    public private(set) var device = ""
    /// The moment relative times render against. It advances only on owner
    /// events and user actions, so an idle panel never wakes up.
    public private(set) var now: Date

    // MARK: Client view state (never sent to the owner)

    /// The selected item (inbox). Changes only from user actions.
    public var selection: String?
    /// Unsent answers, per item.
    public var drafts = FeedDrafts()

    /// Opens an item's context with focus (the App: terminal, browser tab,
    /// sign-in pane). Called only from user actions.
    public var onOpenItem: (@MainActor (FeedItem) -> Void)?
    /// Opens the feed panel (the menu bar's "Open Feed").
    public var onOpenFeed: (@MainActor () -> Void)?

    private let source: any FeedSource
    private let clock: @MainActor () -> Date

    public init(source: any FeedSource, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.source = source
        self.clock = clock
        now = clock()
    }

    public func start() {
        source.start { [weak self] event in self?.handle(event) }
    }

    public func stop() {
        source.stop()
    }

    // MARK: - Visible state

    /// Mirror + pending intents, newest first.
    public var visibleItems: [FeedItem] {
        var items = confirmed
        for intent in pending {
            intent.apply(to: &items, user: user, device: device)
        }
        return items.values.sorted(by: FeedOrder.newest)
    }

    public func item(_ id: String) -> FeedItem? {
        guard var items = confirmed[id].map({ [id: $0] }) else { return nil }
        for intent in pending where intent.items?.contains(id) ?? true {
            intent.apply(to: &items, user: user, device: device)
        }
        return items[id]
    }

    public var listSections: FeedListSections { FeedListSections(items: visibleItems, now: now) }
    public var inboxGroups: FeedInboxGroups { FeedInboxGroups(items: visibleItems, now: now) }
    public var menubarItems: [FeedItem] { FeedOrder.menubar(visibleItems, now: now) }
    public var counts: FeedCounts { FeedCounts(items: visibleItems, now: now) }

    /// An intent on this item still waits for the owner.
    public func isPending(_ id: String) -> Bool {
        pending.contains { $0.items?.contains(id) ?? true }
    }

    // MARK: - Intents

    /// Sends an intent. Refused while the owner is unreachable (nothing queues).
    @discardableResult
    public func send(_ kind: FeedIntentKind) -> FeedIntent? {
        now = clock()
        guard connection == .connected else {
            lastReject = .disconnected
            return nil
        }
        lastReject = nil
        let intent = FeedIntent(kind: kind, at: now)
        pending.append(intent)
        source.send(intent)
        return intent
    }

    /// Answers a request. A request that already closed (answered on
    /// another device, expired) is not sent: the panel shows its closed state.
    @discardableResult
    public func answer(_ id: String, _ value: FeedAnswerValue) -> FeedIntent? {
        guard let item = item(id), item.isRequest else { return nil }
        guard item.state == .open else {
            lastReject = .closed(item)
            return nil
        }
        let intent = send(.answer(item: id, value: value))
        if intent != nil { drafts.clear(id) }
        return intent
    }

    /// Sends the drafted choice answer, or returns why it cannot be sent.
    @discardableResult
    public func submitChoice(_ id: String) -> [FeedChoiceIssue] {
        guard let item = item(id), case let .choice(prompt) = item.prompt else { return [] }
        let answers = drafts.choices[id] ?? [:]
        guard let normalized = FeedChoiceValidation.normalized(answers, for: prompt) else {
            return FeedChoiceValidation.issues(answers, for: prompt)
        }
        answer(id, .choice(normalized))
        return []
    }

    public func decline(_ id: String) {
        guard let item = item(id), item.isRequest else { return }
        guard item.state == .open else {
            lastReject = .closed(item)
            return
        }
        send(.decline(item: id))
    }

    public func markRead(_ ids: [String]) {
        let unread = ids.filter { item($0)?.isUnread == true }
        if !unread.isEmpty { send(.read(items: unread)) }
    }

    public func archive(_ ids: [String]) {
        let archivable = ids.filter { item($0).map { !$0.isOpenRequest && !$0.isArchived } ?? false }
        if !archivable.isEmpty { send(.archive(items: archivable)) }
    }

    public func snooze(_ ids: [String], for interval: TimeInterval) {
        let snoozable = ids.filter { item($0).map { !$0.isOpenRequest } ?? false }
        if !snoozable.isEmpty { send(.snooze(items: snoozable, until: clock().addingTimeInterval(interval))) }
    }

    public func markAllRead() {
        guard visibleItems.contains(where: \.isUnread) else { return }
        send(.markAllRead(before: clock()))
    }

    /// A user selected an item (click, Return): select it and read it.
    public func select(_ id: String) {
        selection = id
        markRead([id])
    }

    /// A user opened an item (double click, Open, Sign In): select, read,
    /// and hand its context to the App.
    public func open(_ id: String) {
        select(id)
        if let item = item(id) { onOpenItem?(item) }
    }

    public func openFeed() {
        onOpenFeed?()
    }

    /// The user dismissed the refusal notice.
    public func clearReject() {
        lastReject = nil
    }

    // MARK: - Owner data

    func handle(_ event: FeedSourceEvent) {
        now = clock()
        switch event {
        case let .connection(state):
            connection = state
        case let .snapshot(snapshot):
            revision = snapshot.revision
            user = snapshot.user
            device = snapshot.device
            confirmed = Dictionary(snapshot.items.map { ($0.id, $0) }) { _, last in last }
            connection = .connected
        case let .event(event):
            revision = max(revision, event.revision)
            switch event.change {
            case let .items(items): items.forEach(adopt)
            case let .remove(ids): ids.forEach { confirmed[$0] = nil }
            }
            if let tx = event.tx { pending.removeAll { $0.key == tx } }
        case let .settled(key, reject):
            pending.removeAll { $0.key == key }
            if let reject {
                if let item = reject.closedItem { adopt(item) }
                lastReject = reject
            }
        }
    }

    /// Writes owner data into the mirror; never moves an item backwards.
    private func adopt(_ item: FeedItem) {
        if let current = confirmed[item.id], current.revision > item.revision { return }
        confirmed[item.id] = item
    }
}
