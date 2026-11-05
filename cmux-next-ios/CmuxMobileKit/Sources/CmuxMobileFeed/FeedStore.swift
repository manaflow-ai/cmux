import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import Observation
import OSLog

#if DEBUG
private let feedChurnLog = Logger(subsystem: "dev.cmux.mobile", category: "feed-churn")
#endif

/// One Feed event: something an agent did or needs, from any workspace and tab.
public struct FeedItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A normal agent reply; Reply sends a new prompt into that tab.
        case response
        case question(AgentQuestion)
        case permission(ACPPermissionRequest)
        case finished
        case failed
        /// A terminal agent (Codex, Claude Code in a terminal tab) waits for the
        /// person: an approval or a question in its TUI. It is answered in the
        /// terminal, so the item opens the tab instead of answering inline.
        case needsInput
    }

    /// The message this event answers, shown as an iMessage-style quote bubble.
    public struct Quote: Hashable, Sendable {
        public enum Author: Hashable, Sendable { case you, agent }
        public var text: String
        public var author: Author

        public init(_ text: String, author: Author = .you) {
            self.text = text
            self.author = author
        }
    }

    public var id: String
    public var kind: Kind
    public var workspaceID: String
    public var tabID: String
    public var agentName: String
    public var harness: String
    public var workspaceTitle: String
    /// The tab the agent runs in, as the Mac names it ("Fix login redirect"); empty when unknown.
    public var tabTitle = ""
    public var markdown: String
    public var quote: Quote?
    public var createdAt: Date
    public var isRead = false
    /// Marked done (swipe): hidden from the Feed like an archived mail.
    public var isDone = false
    /// Set once answered inline (question, permission) or replied to.
    public var resolution: String?
    public var replies: [String] = []
    /// The Mac refused the inline answer (shown under the card; the ask stays open).
    public var error: String?
    /// Bumps with each inline answer, so a late refusal never reverts a newer answer.
    public var attempt = 0
    /// An answer on its way that is not decided yet ("Sending…"):
    /// the card shows it instead of its buttons, and never claims "Allowed"
    /// before the signed answer went out (review m10).
    public var pending: String?
    /// The event came from a terminal tab (a terminal agent's notification):
    /// opening it shows the terminal, and it takes no inline reply.
    public var opensTerminal = false
    /// The Mac whose agent sent the event: answers, replies and opens go to
    /// that Mac's link, never the chosen one's (nil: mock content, old archives).
    public var macID: String?
    /// The page the event opens instead of a chat: a request of the Mac app's own Feed (a PR
    /// held for trial, `MacNeedsYouFeed`), answered there, not in a chat or a terminal.
    public var link: URL?

    public init(
        id: String, kind: Kind, workspaceID: String, tabID: String, agentName: String, harness: String,
        workspaceTitle: String, markdown: String, quote: Quote?, createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.agentName = agentName
        self.harness = harness
        self.workspaceTitle = workspaceTitle
        self.markdown = markdown
        self.quote = quote
        self.createdAt = createdAt
    }

    /// The card takes a typed reply: a chat's events, and a terminal agent's
    /// finished turn (typed into that terminal). A terminal agent's question,
    /// approval or error is handled in the terminal (after an error the agent
    /// may still be working).
    public var takesReply: Bool {
        !opensTerminal || kind == .response || kind == .finished
    }

    /// Where it happened: "api-server › Fix login redirect", or the workspace alone when the tab
    /// is unnamed or only repeats the agent's name.
    public var place: String {
        let tab = tabTitle.trimmingCharacters(in: .whitespaces)
        let repeats = [agentName, harness, workspaceTitle].contains { $0.caseInsensitiveCompare(tab) == .orderedSame }
        guard !tab.isEmpty, !repeats else { return workspaceTitle }
        return workspaceTitle.isEmpty ? tab : "\(workspaceTitle) › \(tab)"
    }

    public var needsYou: Bool {
        guard resolution == nil else { return false }
        switch kind {
        case .question(let question): return question.isPending
        case .permission, .needsInput: return true
        default: return false
        }
    }
}

public enum FeedFilter: String, CaseIterable, Hashable, Sendable {
    case all = "All", needsYou = "Needs you", finished = "Finished", errors = "Errors"

    func matches(_ item: FeedItem) -> Bool {
        switch self {
        case .all: true
        case .needsYou: item.needsYou
        case .finished: item.kind == .finished || item.kind == .response
        case .errors: item.kind == .failed
        }
    }
}

/// Where inline answers go (the live acpmux hub). Without one, an answer
/// fails visibly; only DEBUG mock content answers locally.
@MainActor
public protocol FeedActions: AnyObject {
    /// Re-reads the Mac's sessions and open asks (pull to refresh).
    func refresh() async throws
    func answer(_ item: FeedItem, question: AgentQuestion, with answer: AgentQuestionAnswer) async throws
    func respond(_ item: FeedItem, request: ACPPermissionRequest, option: ACPPermissionOption) async throws
    /// Declines a question: the one reply a phone can always send.
    func decline(_ item: FeedItem, question: AgentQuestion) async throws
    /// Display copy for a refused answer.
    func message(for error: any Error) -> String
    /// The ask was already answered (on the Mac or another device): the card closes
    /// instead of reopening with the Mac's raw "no pending permission".
    func isAlreadyAnswered(_ error: any Error) -> Bool
}

public extension FeedActions {
    func isAlreadyAnswered(_ error: any Error) -> Bool { false }
}

/// The Feed's state: newest first. Empty until `CmuxMobileLive` fills it with
/// events from acpmux `_acpmux/watch`; sample items only in DEBUG builds with
/// mock content on.
@MainActor
@Observable
public final class FeedStore {
    @ObservationIgnored public weak var actions: (any FeedActions)?
    public static let shared = FeedStore(
        items: FeedStore.initialItems(mockContentEnabled: DeveloperOptions.mockContentEnabled),
        answersLocally: DeveloperOptions.mockContentEnabled,
        readMarks: .standard
    )
    /// DEBUG mock content only: with no Mac behind the Feed, answers apply
    /// locally. Otherwise an answer with no `actions` fails on the item.
    @ObservationIgnored public let answersLocally: Bool
    /// Why the last pull to refresh failed (nil after a good one).
    public private(set) var refreshError: String?

    /// Shown on an item answered while no Mac is connected.
    public static let notConnectedMessage = "Not connected to your Mac. Nothing was sent."

    /// The Feed before live data: sample items only with mock content on (DEBUG).
    static func initialItems(mockContentEnabled: Bool) -> [FeedItem] {
        #if DEBUG
        if mockContentEnabled { return FeedStore.mockItems(now: Date()) }
        #endif
        return []
    }

    public private(set) var items: [FeedItem] {
        didSet {
            guard items != oldValue else { return }
            // Events read before (this launch or an earlier one) stay read when the Mac
            // reports them again.
            if items.contains(where: { !$0.isRead && readSet.contains($0.id) }) {
                items = items.map { item in
                    var item = item
                    if readSet.contains(item.id) { item.isRead = true }
                    return item
                }
                return
            }
            // A done event that left the window stays done when the Mac reports it again.
            if !evictedDoneSet.isEmpty, items.contains(where: { !$0.isDone && evictedDoneSet.contains($0.id) }) {
                items = items.map { item in
                    var item = item
                    if evictedDoneSet.contains(item.id) { item.isDone = true }
                    return item
                }
                return
            }
            reindex()
            recordReadMarks()
            refreshDerived()
            #if DEBUG
            if FeedStressRig.shared.config.logsChurn { FeedStore.logChange(from: oldValue, to: items) }
            #endif
            onItemsChange?(items)
        }
    }

    /// How many events the Feed holds in memory: the newest, plus any open ask
    /// older than them (an ask is never dropped while it waits for an answer).
    /// The Mac's own ledger keeps 256 terminal events and the archive saves 200,
    /// so the window only bounds what a long-running app collects live.
    public static let memoryLimit = 500
    /// Done flags of events dropped from the window, newest last: the Mac
    /// re-reports its ledger, and a done event it brings back stays hidden.
    static let evictedDoneLimit = 1000
    @ObservationIgnored private var evictedDoneIDs: [String] = [] {
        didSet { evictedDoneSet = Set(evictedDoneIDs) }
    }
    @ObservationIgnored private var evictedDoneSet: Set<String> = []

    /// An older event the window keeps: an open ask, one with an answer on its way or a refusal
    /// to show, and the one Undo can still bring back.
    private func keepsOutsideWindow(_ item: FeedItem) -> Bool {
        (item.needsYou && !item.isDone) || item.pending != nil || item.error != nil || item.id == lastDoneID
    }

    /// The newest `memoryLimit` events in Feed order, and every older event `keepsOutsideWindow`.
    /// Applied only where events arrive (`insert`, `mergeHistory`, `replaceAll`), never in the
    /// write of something the person did to one (an answer, a read, Done).
    private func windowed(_ all: [FeedItem]) -> [FeedItem] {
        var kept: [FeedItem] = []
        kept.reserveCapacity(Self.memoryLimit)
        var evictedDone: [String] = []
        for (offset, item) in all.enumerated() {
            if offset < Self.memoryLimit || keepsOutsideWindow(item) {
                kept.append(item)
            } else if item.isDone {
                evictedDone.append(item.id)
            }
        }
        if !evictedDone.isEmpty {
            let known = evictedDoneSet
            evictedDoneIDs = Array((evictedDoneIDs + evictedDone.filter { !known.contains($0) }).suffix(Self.evictedDoneLimit))
        }
        if !unseenNewIDs.isEmpty {
            let present = Set(kept.map(\.id))
            let unseen = unseenNewIDs.filter(present.contains)
            if unseen != unseenNewIDs { unseenNewIDs = unseen }
        }
        return kept
    }

    /// Writes `next` only when it differs. The Mac re-reports the same
    /// history on every tree change (several a second while an agent works),
    /// and an in-place write (`items[i] = x`, `mutate`) notifies observers even
    /// when nothing changed: the Feed re-rendered and re-saved for nothing.
    /// The window and the evicted done flags apply before the comparison, so a
    /// re-reported history the window already dropped is no change at all.
    private func setItems(_ next: [FeedItem]) {
        var next = next
        if !evictedDoneSet.isEmpty {
            for index in next.indices where !next[index].isDone && evictedDoneSet.contains(next[index].id) {
                next[index].isDone = true
            }
        }
        if next.count > Self.memoryLimit { next = windowed(next) }
        if next != items { items = next }
    }

    /// The filtered list and the count, kept with the items instead of
    /// recomputed by every body that reads them.
    private func refreshDerived() {
        let visible = Self.pinningNeedsYou(items.filter { !$0.isDone && filter.matches($0) && !mutedWorkspaces.contains($0.workspaceID) })
        if visible != visibleItems { visibleItems = visible }
        let open = Set(items.lazy.filter { $0.needsYou && !$0.isDone }.map(\.id))
        if open != needsYouIDs { needsYouIDs = open }
        if open.count != needsYouCount { needsYouCount = open.count }
    }

    /// Needs you first: the asks still waiting on the person lead the list, newest first among
    /// them, then every other event newest first. The Mac's Feed pins its open requests the same
    /// way (CmuxNextFeed `FeedLedger`, section 0), so an ask never sinks under later turns.
    nonisolated static func pinningNeedsYou(_ items: [FeedItem]) -> [FeedItem] {
        // Stable: each group keeps the order it came in (newest first).
        guard items.contains(where: \.needsYou) else { return items }
        return items.filter(\.needsYou) + items.filter { !$0.needsYou }
    }

    /// Whether the Feed knows the ask with acpmux permission `permissionID` from `mac` closed:
    /// answered here, on the Mac or on another device, or marked done. Nil `mac` (a push from an
    /// older Worker) matches the ask on any Mac. False for an ask the Feed has not read yet (a
    /// reconnect that has not reloaded it); an Allow still on its way has no resolution
    /// yet, so it stays open.
    public func isClosedAsk(permissionID: String, mac: String?) -> Bool {
        guard let item = item(id: "ask-\(permissionID)") else { return false }
        if let mac, let owner = item.macID, mac != owner { return false }
        return item.isDone || !item.needsYou
    }

    /// The Macs whose own Feed requests (`MacNeedsYouFeed`) were read on their live link.
    @ObservationIgnored public var macRequestsRead: Set<String> = []

    /// Whether the Feed knows the Mac app's Feed request of push `eventID` (`feed-<id>`, from
    /// cmux-mobile-host `needs_you.rs`) on `mac` closed: that Mac's live list no longer has it,
    /// or it was marked done. False until that Mac's list was read on its live link.
    public func isClosedMacRequest(eventID: String, mac: String?) -> Bool {
        guard eventID.hasPrefix("feed-"), let mac, macRequestsRead.contains(mac) else { return false }
        guard let item = item(id: "macreq-\(mac)-\(eventID.dropFirst(5))") else { return true }
        return item.isDone || !item.needsYou
    }

    /// Persisted read flags (`FeedReadMarks`); nil keeps them in memory only (tests).
    @ObservationIgnored private var readMarks: FeedReadMarks?
    @ObservationIgnored private var readIDs: [String] = [] {
        didSet { readSet = Set(readIDs) }
    }
    /// `readIDs` as a set: every items write checks each item against it.
    @ObservationIgnored private var readSet: Set<String> = []
    /// Where each item is in `items`, by id: lookups from the live ledger (one per entry,
    /// per tree update) were linear scans.
    @ObservationIgnored private var itemIndex: [String: Int] = [:]

    private func reindex() {
        var index: [String: Int] = [:]
        index.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() where index[item.id] == nil { index[item.id] = offset }
        itemIndex = index
    }

    private func recordReadMarks() {
        let read = items.filter(\.isRead).map(\.id)
        let unread = Set(items.filter { !$0.isRead }.map(\.id))
        var next = readIDs.filter { !unread.contains($0) }
        let known = Set(next)
        next += read.filter { !known.contains($0) }
        guard next != readIDs else { return }
        readIDs = next
        readMarks?.save(next)
    }
    /// Called after every change (live mode saves the Feed with `FeedArchive`).
    @ObservationIgnored public var onItemsChange: (@MainActor ([FeedItem]) -> Void)?
    public var filter: FeedFilter = .all {
        didSet { if filter != oldValue { refreshDerived() } }
    }
    /// Whether the Mac's events have been read on the current link. Until
    /// then an empty Feed is unknown, not empty (live mode starts at
    /// `.connecting`; mock mode is always `.live`).
    public var syncState: SyncState = .live
    public enum SyncState: Hashable, Sendable { case connecting, live }
    public var mutedWorkspaces: Set<String> = [] {
        didSet { if mutedWorkspaces != oldValue { refreshDerived() } }
    }
    /// Events that arrived while the person was scrolled away from the top.
    public private(set) var unseenNewIDs: [String] = []
    private var liveIndex = 0

    public init(items: [FeedItem], answersLocally: Bool = false, readMarks: FeedReadMarks? = nil) {
        self.readMarks = readMarks
        let readIDs = readMarks?.load() ?? []
        self.readIDs = readIDs
        readSet = Set(readIDs)
        let read = readSet
        self.items = items.sorted { $0.createdAt > $1.createdAt }.map { item in
            var item = item
            if read.contains(item.id) { item.isRead = true }
            return item
        }
        self.answersLocally = answersLocally
        reindex()
        refreshDerived()
    }

    /// Pull to refresh: re-reads the Mac's sessions and open asks through
    /// `actions`. Fails visibly (`refreshError`) with no Mac connected.
    public func refresh() async {
        guard let actions else {
            refreshError = answersLocally ? nil : Self.notConnectedMessage
            return
        }
        do {
            try await actions.refresh()
            refreshError = nil
        } catch is CancellationError {
        } catch {
            refreshError = actions.message(for: error)
        }
    }

    /// Recovery finishes opening the Macs' feeds before reading them again.
    public func retry(reconnect: @MainActor () async -> Void = {}) async {
        await reconnect()
        guard !Task.isCancelled else { return }
        await refresh()
    }

    #if DEBUG
    public func setRefreshErrorForDemo() {
        refreshError = Self.notConnectedMessage
    }
    #endif

    public func clearRefreshError() { refreshError = nil }

    /// No Mac to send to: the item keeps its question and says why.
    private func failUnsent(_ id: String) {
        mutate(id) { $0.error = Self.notConnectedMessage }
    }

    /// What the Feed lists: not done, matching the filter, not muted (newest first).
    public private(set) var visibleItems: [FeedItem] = []

    public private(set) var needsYouCount = 0
    /// The ids of the asks still waiting on the person (`needsYou`, not done). It changes only
    /// when an ask opens or closes: the notification sync keys on it, so a re-render or a re-read
    /// of the same asks does nothing.
    public private(set) var needsYouIDs: Set<String> = []

    public func count(_ filter: FeedFilter) -> Int { items.count(where: filter.matches) }

    public func insert(_ item: FeedItem, atTop: Bool) {
        if !atTop { unseenNewIDs.append(item.id) }
        var next = items
        next.insert(item, at: 0)
        setItems(next)
    }

    public func clearUnseen() {
        if !unseenNewIDs.isEmpty { unseenNewIDs = [] }
    }

    public func markRead(_ id: String) { mutate(id) { $0.isRead = true } }

    /// Marks several events read in one write (the Mac's reads arrive together).
    public func markRead(_ ids: some Sequence<String>) {
        var next = items
        var changed = false
        for id in ids {
            guard let index = itemIndex[id], !next[index].isRead else { continue }
            next[index].isRead = true
            changed = true
        }
        if changed { items = next }
    }

    /// Mark All Notifications as Read: every event in the Feed, in one write.
    public func markAllRead() {
        guard items.contains(where: { !$0.isRead }) else { return }
        items = items.map { item in
            var item = item
            item.isRead = true
            return item
        }
    }

    public func markUnread(_ id: String) {
        readIDs.removeAll { $0 == id }
        readMarks?.save(readIDs)
        mutate(id) { $0.isRead = false }
    }

    /// Marks an event done (swipe): it leaves the Feed; `undoDone` brings it back.
    public func markDone(_ id: String) {
        mutate(id) {
            $0.isDone = true
            $0.isRead = true
        }
        lastDoneID = id
    }

    public private(set) var lastDoneID: String?

    public func clearDone() { lastDoneID = nil }

    public func undoDone() {
        guard let id = lastDoneID else { return }
        if evictedDoneSet.contains(id) { evictedDoneIDs.removeAll { $0 == id } }
        mutate(id) { $0.isDone = false }
        lastDoneID = nil
    }

    /// Replaces every item (live mode starts empty).
    /// The signed-in account's read flags (`FeedReadMarks.forAccount`): another
    /// account on this phone never sees them, and the same account keeps them
    /// across sign-out (verify/persistence.md).
    public func useReadMarks(_ marks: FeedReadMarks?) {
        readMarks = marks
        readIDs = marks?.load() ?? []
    }

    /// Sign-out: the Feed's items leave memory (the account's archive is
    /// deleted by the caller); nothing is saved for it any more.
    public func clearForSignOut() {
        onItemsChange = nil
        actions = nil
        replaceAll([])
        evictedDoneIDs = []
        useReadMarks(nil)
    }

    public func replaceAll(_ next: [FeedItem]) {
        setItems(next.sorted { $0.createdAt > $1.createdAt })
        clearUnseen()
    }

    /// Inserts or replaces an item by id (live events are idempotent).
    public func upsert(_ item: FeedItem, atTop: Bool) {
        if let index = itemIndex[item.id] {
            var next = item
            next.isRead = items[index].isRead
            next.isDone = items[index].isDone
            next.resolution = items[index].resolution ?? item.resolution
            next.replies = items[index].replies
            if items[index] != next { items[index] = next }
        } else {
            insert(item, atTop: atTop)
        }
    }

    /// Adds history (events from before this launch or this connection) in
    /// time order. Known items keep what the person did with them (read, done,
    /// answered); nothing counts as newly arrived.
    public func mergeHistory(_ history: [FeedItem]) {
        var next = items
        var positions = itemIndex
        for item in history {
            if let index = positions[item.id] {
                var merged = item
                merged.isRead = next[index].isRead
                merged.isDone = next[index].isDone
                merged.resolution = next[index].resolution ?? item.resolution
                merged.replies = next[index].replies
                // A reply on its way, or why the last one failed, outlives a read of the ledger.
                merged.pending = next[index].pending ?? item.pending
                merged.error = next[index].error ?? item.error
                merged.createdAt = next[index].createdAt
                next[index] = merged
            } else {
                positions[item.id] = next.count
                next.append(item)
            }
        }
        setItems(next.sorted { $0.createdAt > $1.createdAt })
    }

    public func item(id: String) -> FeedItem? { itemIndex[id].map { items[$0] } }

    /// Drops an item the source withdrew (a duplicate of another event).
    public func remove(_ id: String) {
        if items.contains(where: { $0.id == id }) { items.removeAll { $0.id == id } }
        if unseenNewIDs.contains(id) { unseenNewIDs.removeAll { $0 == id } }
    }

    /// Marks an open ask resolved elsewhere (another device or the Mac).
    public func resolveElsewhere(_ id: String, text: String) {
        mutate(id) { item in
            guard item.resolution == nil else { return }
            if case .question(var question) = item.kind, question.isPending {
                question.state = .answered(AgentQuestionAnswer(selections: [:]))
                item.kind = .question(question)
            }
            item.resolution = text
        }
    }

    public func answer(_ id: String, answer: AgentQuestionAnswer) {
        if let actions, let item = item(id: id), case .question(let question) = item.kind {
            let attempt = item.attempt + 1
            mutate(id) { $0.error = nil; $0.attempt = attempt }
            applyAnswer(id, answer: answer)
            Task {
                do {
                    try await actions.answer(item, question: question, with: answer)
                } catch {
                    if actions.isAlreadyAnswered(error) { return settleAnsweredElsewhere(id, attempt: attempt) }
                    mutate(id) {
                        guard $0.attempt == attempt else { return }
                        $0.kind = .question(question)
                        $0.resolution = nil
                        $0.error = actions.message(for: error)
                    }
                }
            }
            return
        }
        guard answersLocally else { return failUnsent(id) }
        applyAnswer(id, answer: answer)
    }

    /// Declines a pending question (the agent continues without an answer).
    public func decline(_ id: String) {
        guard let item = item(id: id), case .question(let question) = item.kind, question.isPending else { return }
        guard actions != nil || answersLocally else { return failUnsent(id) }
        let attempt = item.attempt + 1
        mutate(id) {
            $0.error = nil
            $0.attempt = attempt
            var declined = question
            declined.state = .cancelled
            $0.kind = .question(declined)
            $0.resolution = "Declined"
            $0.isRead = true
        }
        guard let actions else { return }
        Task {
            do {
                try await actions.decline(item, question: question)
            } catch {
                if actions.isAlreadyAnswered(error) { return settleAnsweredElsewhere(id, attempt: attempt) }
                mutate(id) {
                    guard $0.attempt == attempt else { return }
                    $0.kind = .question(question)
                    $0.resolution = nil
                    $0.error = actions.message(for: error)
                }
            }
        }
    }

    /// Copy for an ask that another device or the Mac answered first.
    public static let answeredElsewhere = "Already answered on your Mac"

    /// The Mac no longer waits on this ask: close the card, with no error.
    private func settleAnsweredElsewhere(_ id: String, attempt: Int) {
        mutate(id) { item in
            guard item.attempt == attempt else { return }
            item.pending = nil
            item.error = nil
            if case .question(var question) = item.kind, question.isPending {
                question.state = .answered(AgentQuestionAnswer(selections: [:]))
                item.kind = .question(question)
            }
            item.resolution = Self.answeredElsewhere
            item.isRead = true
        }
    }

    private func applyAnswer(_ id: String, answer: AgentQuestionAnswer) {
        mutate(id) { item in
            guard case .question(var question) = item.kind else { return }
            question.state = .answered(answer)
            item.kind = .question(question)
            item.resolution = question.summaryLines(answer).joined(separator: "\n")
            item.isRead = true
        }
    }

    /// Shown on a permission card while its Allow is signed and sent to the Mac.
    public static let sendingAllow = "Sending…"

    public func respond(_ id: String, option: ACPPermissionOption) {
        if let actions, let item = item(id: id), case .permission(let request) = item.kind {
            guard item.pending == nil else { return }
            let attempt = item.attempt + 1
            mutate(id) { $0.error = nil; $0.attempt = attempt }
            // An Allow is signed and says "Allowed" only once it went
            // out. A Deny is not signed and shows at once.
            if option.isAllow {
                mutate(id) { $0.pending = Self.sendingAllow }
            } else {
                applyRespond(id, option: option)
            }
            Task {
                do {
                    try await actions.respond(item, request: request, option: option)
                    guard option.isAllow else { return }
                    mutate(id) {
                        guard $0.attempt == attempt else { return }
                        $0.pending = nil
                        $0.resolution = Self.allowedText(option.name)
                        $0.isRead = true
                    }
                } catch {
                    if actions.isAlreadyAnswered(error) { return settleAnsweredElsewhere(id, attempt: attempt) }
                    mutate(id) {
                        guard $0.attempt == attempt else { return }
                        $0.pending = nil
                        $0.resolution = nil
                        $0.error = actions.message(for: error)
                    }
                }
            }
            return
        }
        guard answersLocally else { return failUnsent(id) }
        let delay = DeveloperOptions.mockApprovalDelay
        if option.isAllow, delay > .zero {
            guard item(id: id)?.pending == nil else { return }
            mutate(id) { $0.pending = Self.sendingAllow }
            Task {
                try? await Task.sleep(for: delay)
                mutate(id) { $0.pending = nil }
                applyRespond(id, option: option)
            }
            return
        }
        applyRespond(id, option: option)
    }

    /// The card's line after an Allow: the option's own words when they say more than
    /// "Allow" ("Allowed: Always for this chat"), else "Allowed" (full verify D12: "Allowed: Allow").
    static func allowedText(_ name: String) -> String {
        let plain = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch plain.lowercased() {
        case "", "allow", "yes", "approve", "ok": return "Allowed"
        case "allow once", "yes, once", "once": return "Allowed once"
        default: return "Allowed: \(plain)"
        }
    }

    private func applyRespond(_ id: String, option: ACPPermissionOption) {
        mutate(id) {
            $0.resolution = option.isAllow ? Self.allowedText(option.name) : "Denied"
            $0.isRead = true
        }
    }

    /// "Typing into the terminal…" while a terminal agent's reply is on its way.
    public static let typingIntoTerminal = "Typing into the terminal…"

    /// A reply to a terminal agent's event, typed into that terminal by
    /// `send` (nil: sent; else why not). Its state lives on the item, so a
    /// recycled cell neither loses the outcome nor sends it twice.
    public func replyToTerminal(_ id: String, text: String, send: @escaping (FeedItem, String) async -> String?) {
        guard let item = item(id: id), item.pending == nil else { return }
        mutate(id) {
            $0.pending = Self.typingIntoTerminal
            $0.error = nil
        }
        Task { @MainActor in
            let refusal = await send(item, text)
            mutate(id) {
                $0.pending = nil
                if let refusal {
                    $0.error = refusal
                } else {
                    $0.replies.append(text)
                    $0.isRead = true
                }
            }
        }
    }

    public func reply(_ id: String, text: String) {
        mutate(id) {
            $0.replies.append(text)
            $0.isRead = true
        }
    }

    private func mutate(_ id: String, _ body: (inout FeedItem) -> Void) {
        guard let index = itemIndex[id] else { return }
        var item = items[index]
        body(&item)
        // An unchanged item is not written (no re-render, no save).
        if item != items[index] { items[index] = item }
    }

    #if DEBUG
    /// The rig's change log: what each write changed (ids and fields), to find churn.
    static func logChange(from old: [FeedItem], to new: [FeedItem]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var fields: [String: Int] = [:]
        var added = 0
        for item in new {
            guard let prior = before[item.id] else { added += 1; continue }
            guard prior != item else { continue }
            let a = Mirror(reflecting: prior).children, b = Mirror(reflecting: item).children
            for (x, y) in zip(a, b) where String(describing: x.value) != String(describing: y.value) {
                fields[x.label ?? "?", default: 0] += 1
            }
        }
        let summary = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        feedChurnLog.notice("FEEDCHURN added=\(added, privacy: .public) removed=\(max(0, old.count + added - new.count), privacy: .public) changed=\(summary, privacy: .public)")
    }

    /// Adds the next scripted live event (mock arrivals; demo driver uses it).
    public func injectLiveEvent(atTop: Bool) {
        let samples = FeedStore.liveSamples(now: Date())
        let item = samples[liveIndex % samples.count]
        liveIndex += 1
        var copy = item
        copy.id = "\(item.id)-\(liveIndex)"
        insert(copy, atTop: atTop)
    }
    #endif
}
