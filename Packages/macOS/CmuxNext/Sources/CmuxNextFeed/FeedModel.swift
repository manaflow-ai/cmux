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
    /// Quiet local agent reports, read from the ACPMUX reports mailbox.
    /// Reports are intentionally separate from owner-confirmed feed items.
    public private(set) var reports: [FeedReport] = []
    /// Pending intents in send order.
    public private(set) var pending: [FeedIntent] = []
    /// The feed as shown, kept up to date per change (``FeedLedger``): every read below is served
    /// from it, and the list hears each change as row edits (``observeList(_:)``).
    @ObservationIgnored private(set) var ledger = FeedLedger()
    /// Bumps once per change of anything shown: a reader that needs more than the row edits
    /// (the Inbox groups) observes this.
    public private(set) var version = 0
    /// The list subscriptions, held weakly: a released one leaves on its own, on any thread.
    @ObservationIgnored private let listeners = NSHashTable<FeedListSubscription>.weakObjects()
    @ObservationIgnored private var inboxMemo: (version: Int, now: Date, filter: FeedInboxFilter, groups: FeedInboxGroups)?
    @ObservationIgnored private var visibleMemo: (version: Int, items: [FeedItem])?
    /// The last refusal, for the panel's notice; cleared on the next send.
    public private(set) var lastReject: FeedReject?
    public private(set) var revision: UInt64 = 0
    public private(set) var user = ""
    public private(set) var device = ""
    /// What the panel chrome shows (the badge, whether the list is empty), stored and set only when
    /// it changes: the panel's header and empty state observe this, not the whole mirror, so an
    /// owner event that changes neither re-evaluates no SwiftUI view.
    public private(set) var summary = FeedSummary()
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
    /// Refreshes integration sources such as GitHub. The owner remains the
    /// authority for feed state; this is only a user-triggered source wakeup.
    public var onRefresh: (@MainActor () -> Void)?
    /// Routes a supported GitHub action to the host. Unsupported actions stay hidden.
    public var onGitHubAction: (@MainActor (FeedItem, FeedGitHubAction, String?) -> Void)?
    /// Host capability check keeps unsupported actions out of the detail pane.
    public var githubActions: (@MainActor (FeedItem) -> Set<FeedGitHubAction>)?
    /// Resolves client-only GitHub detail for an owner item without storing a
    /// second inbox projection in the view layer.
    public var githubDetail: (@MainActor (FeedItem) -> GitHubFeedDetail?)?
    /// Names an item's agent, workspace and tab from the App's own store (items carry only ids).
    /// Read when a row is built, so a renamed tab shows on the item's next change.
    public var place: (@MainActor (FeedItem) -> FeedPlace?)?
    public var githubActionError: String?
    public var githubActionPending = false
    /// Whether the opt-in GitHub connection is enabled for this owner.
    public var githubConnectionEnabled = false

    /// Opens the host-owned integration settings from a user action.
    public var onAddConnection: (@MainActor () -> Void)?

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
        reports.removeAll()
    }

    // MARK: - Visible state

    /// Mirror + pending intents, newest first.
    public var visibleItems: [FeedItem] {
        let version = version
        if let memo = visibleMemo, memo.version == version { return memo.items }
        let items = ledger.timeline.ids.compactMap { ledger.visible[$0] }
        visibleMemo = (version, items)
        return items
    }

    public func item(_ id: String) -> FeedItem? {
        ledger.visible[id]
    }

    /// The panel list's rows, in order (open requests, then the rest).
    public var listCount: Int { ledger.list.count }

    /// The item on list row `row`.
    public func listItem(at row: Int) -> FeedItem? {
        let ids = ledger.list.ids
        return ids.indices.contains(row) ? ledger.visible[ids[row]] : nil
    }

    /// The row of `id` in the panel list.
    public func listRow(of id: String) -> Int? { ledger.list.position(of: id) }

    /// Changes each time the item's visible value or its pending state changes.
    public func stamp(of id: String) -> Int { ledger.stamps[id] ?? 0 }

    public var listSections: FeedListSections {
        _ = version
        let ids = ledger.list.ids, requests = ledger.openRequests
        return FeedListSections(requests: ids.prefix(requests).compactMap { ledger.visible[$0] },
                                rest: ids.dropFirst(requests).compactMap { ledger.visible[$0] })
    }

    public var counts: FeedCounts {
        _ = version
        return ledger.counts
    }

    /// The Inbox groups of the items `filter` keeps, from the list's order (no sorting).
    func inboxGroups(_ filter: FeedInboxFilter) -> FeedInboxGroups {
        let version = version, now = now
        if let memo = inboxMemo, memo.version == version, memo.now == now, memo.filter == filter { return memo.groups }
        let groups = FeedInboxGroups(sections: listSections, filter: filter, now: now)
        inboxMemo = (version, now, filter, groups)
        return groups
    }

    /// Calls `body` with the panel list's row edits after each commit, until the subscription
    /// ends (``FeedListSubscription/cancel()`` or its release). An empty edit means only `now`
    /// moved (relative times). A subscriber reads the rows it
    /// has not seen yet with ``listCount`` and ``listItem(at:)`` when it starts.
    public func observeList(_ body: @escaping @MainActor (FeedRowChanges) -> Void) -> FeedListSubscription {
        let subscription = FeedListSubscription(body)
        listeners.add(subscription)
        return subscription
    }

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
        commit(touched: intent.items.map(Set.init) ?? Set(ledger.visible.keys), forcing: true)
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
        guard ledger.unread > 0 else { return }
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

    public func refresh() {
        onRefresh?()
    }

    /// The user dismissed the refusal notice.
    public func clearReject() {
        lastReject = nil
    }

    /// Replaces the local reports projection after a durable mailbox read.
    /// This does not alter feed owner state or triage intents.
    public func replaceReports(_ reports: [FeedReport]) {
        self.reports = reports.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Owner data

    func handle(_ event: FeedSourceEvent) {
        now = clock()
        var touched = Set<String>()
        var forced = false
        switch event {
        case let .connection(state):
            connection = state
        case let .snapshot(snapshot):
            revision = snapshot.revision
            user = snapshot.user
            device = snapshot.device
            touched = Set(confirmed.keys)
            confirmed = Dictionary(snapshot.items.map { ($0.id, $0) }) { _, last in last }
            touched.formUnion(confirmed.keys)
            connection = .connected
        case let .event(event):
            revision = max(revision, event.revision)
            switch event.change {
            case let .items(items):
                items.forEach(adopt)
                touched.formUnion(items.map(\.id))
            case let .remove(ids):
                ids.forEach { confirmed[$0] = nil }
                touched.formUnion(ids)
            }
            if let tx = event.tx { touched.formUnion(settle { $0.key == tx }) }
            forced = event.tx != nil
        case let .settled(key, reject):
            touched.formUnion(settle { $0.key == key })
            forced = true
            if let reject {
                if let item = reject.closedItem {
                    adopt(item)
                    touched.insert(item.id)
                }
                lastReject = reject
            }
        }
        commit(touched: touched, forcing: forced)
    }

    /// Ends the intents `matches` names; returns the items they touched.
    private func settle(_ matches: (FeedIntent) -> Bool) -> Set<String> {
        var touched = Set<String>()
        for intent in pending where matches(intent) {
            touched.formUnion(intent.items ?? Array(ledger.visible.keys))
        }
        pending.removeAll(where: matches)
        return touched
    }

    /// Recomputes the touched items (and snoozes that ended by `now`), then tells the list and
    /// the chrome. `forcing`: an intent on them started or settled, so their rows redraw (pending
    /// dimming) even when their value did not change.
    private func commit(touched: Set<String>, forcing: Bool) {
        let ids = touched.union(ledger.woken(at: now))
        let (changes, changed) = ledger.update(ids, confirmed: confirmed, pending: pending, user: user, device: device,
                                               now: now, forced: forcing ? touched : [])
        // Every commit reaches the list: no row edits still means `now` moved (relative times).
        for listener in listeners.allObjects { listener.body?(changes) }
        guard changed else { return }
        version &+= 1
        let next = FeedSummary(counts: ledger.counts, listIsEmpty: ledger.list.count == 0, hasUnread: ledger.unread > 0)
        if next != summary { summary = next }
    }

    /// Writes owner data into the mirror; never moves an item backwards.
    private func adopt(_ item: FeedItem) {
        if let current = confirmed[item.id], current.revision > item.revision { return }
        confirmed[item.id] = item
    }
}

/// The panel chrome's view of the feed: the badge counts, whether the list has anything, and
/// whether anything is unread. Set only when it changes.
public nonisolated struct FeedSummary: Sendable, Equatable {
    public var counts = FeedCounts(openRequests: 0, unreadNotices: 0)
    public var listIsEmpty = true
    public var hasUnread = false
}

/// A ``FeedModel/observeList(_:)`` registration; ends on ``cancel()`` or when released.
///
/// The model holds it weakly and the subscription holds the body, so a release on any thread ends
/// it (#26698: a deinit that ended it only on the main thread left a released one registered).
@MainActor
public final class FeedListSubscription {
    fileprivate private(set) var body: (@MainActor (FeedRowChanges) -> Void)?

    init(_ body: @escaping @MainActor (FeedRowChanges) -> Void) {
        self.body = body
    }

    public func cancel() {
        body = nil
    }
}
