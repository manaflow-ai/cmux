public import CmuxNextDaemon
import Foundation
public import Observation

/// The Home list's rows as the local conversation owner derives them (`home-inbox`, home-inbox-v1):
/// kind, name (a Chief's registry name), unread, the person's pins and marks, in list order. The
/// Messages list maps these rows and keeps no rules of its own, so it shows what the Channels page
/// shows. `rows` is nil while the owner does not serve `home-inbox` (an older daemon): the list
/// then keeps its own path. Pins and marks are written with `conversation-inbox-op`.
@Observable @MainActor
public final class HomeInboxSource {
    /// The owner's reply (rows in list order, the Cloud state); nil without an owner that serves `home-inbox`.
    public private(set) var reply: HomeInboxRequest.Response?
    public var rows: [HomeInboxRequest.Row]? { reply?.rows }
    /// The owner answered this launch (rows, or that it serves no `home-inbox`). Until then `reply`
    /// may be the last launch's rows (`seed`), so the list's first frame is the list as it was.
    @ObservationIgnored public private(set) var answered = false
    /// `["local"]` for the Chief home's daemon, `["cloud"]` for the build's daemon (its Cloud lease).
    public let owners: [String]
    private var isCloud: Bool { owners == ["cloud"] }
    @ObservationIgnored private var connection: DaemonConnection?
    /// Bumped by each new connection: a reply for an older one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    /// Batches of inbox ops not answered yet: a read meanwhile would undo the local edit, so it is
    /// dropped and one read runs after the last answer.
    @ObservationIgnored private var pendingWrites = 0
    /// Told after each owner reply that is kept (the one-time move of this Mac's pins, `HomePinMigration`).
    @ObservationIgnored public var onRows: (@MainActor () -> Void)?

    /// Owner events after which the rows are asked again (coalesced), besides `conversation-changed`
    /// (spec `home-inbox`). The list shows no Chief state, so typing and run changes are not among them.
    public static let rowEvents: Set<String> = ["conversation-inbox-changed", "chief-changed"]

    public init(owners: [String]) { self.owners = owners }

    /// A new owner connection (or none): the rows are read again from it. The last rows stay while
    /// the owner reconnects, so the list does not fall back to the old order and back.
    public func connectionChanged(_ connection: DaemonConnection?) {
        self.connection = connection
        generation += 1
        refresh()
    }

    /// One owner event: a change that can move a row asks for the rows again.
    public func note(_ event: DaemonEvent) {
        switch event {
        case .conversationChanged: if !isCloud { refresh() }
        case .unknown(let name, _) where Self.rowEvents.contains(name): if !isCloud { refresh() }
        case .cloudConversations(let cloud) where isCloud:
            switch cloud {
            case .inboxChanged, .inboxReset, .resynced, .subscriptionState: refresh()
            default: break
            }
        default: break
        }
    }

    /// Reads the rows; one read at a time, and a request during a read runs one more read after it.
    public func refresh() {
        guard connection != nil else { return }
        if reading { readAgain = true; return }
        reading = true
        // task-owner: one home-inbox read (and one more per request made during it); ends with its reply
        Task { [weak self] in
            while let self, let connection = self.connection {
                let generation = self.generation
                readAgain = false
                let read = await Self.read(connection, owners: owners)
                guard generation == self.generation else { continue }
                switch read {
                case .unsupported:
                    answered = true
                    if reply != nil { reply = nil }
                case .reply(let next): accept(next)
                case .failed: break
                }
                if !readAgain { break }
            }
            self?.reading = false
        }
    }

    /// The last launch's rows (`HomeSidebarLaunchCache`), shown until the owner answers; nothing
    /// once it has. The owner's first answer replaces them in place (the list moves only what changed).
    public func seed(_ last: HomeInboxRequest.Response?) {
        guard !answered, reply == nil, let last else { return }
        reply = last
    }

    /// One owner reply: kept unless an edit is still unanswered.
    func accept(_ reply: HomeInboxRequest.Response) {
        var next = reply
        // The Cloud did not answer: its last rows (this session's or the launch's) stay, only the state changes.
        if next.cloud == "unavailable", let last = self.reply { next.rows = last.rows }
        guard pendingWrites == 0 else { return }
        answered = true
        if self.reply != next { self.reply = next }
        onRows?()
    }

    private enum Read: Sendable { case unsupported, reply(HomeInboxRequest.Response), failed }

    private static func read(_ connection: DaemonConnection, owners: [String]) async -> Read {
        guard await connection.identity?.supports(DaemonCapability.homeInbox.rawValue) == true else { return .unsupported }
        // The Cloud rows are every page of the inbox, read by the daemon within its budget plus one
        // page's read (under the Cloud's 30 s request timeout); the local rows answer at once.
        let timeout: Duration? = owners.contains("cloud") ? CloudConversationClient.networkTimeout : nil
        guard let reply = try? await connection.request(HomeInboxRequest(owners: owners), timeout: timeout) else { return .failed }
        return .reply(reply)
    }

    // MARK: Writes (the person's own list state; the owner's rows follow with its event)

    /// Pins (after the person's other pins) or unpins `id`.
    public func setPinned(_ on: Bool, _ id: String) {
        edit(id) { row in
            row.pinned = on
            row.pinPosition = on ? Self.now() : nil
        }
        if on, let index = rows?.firstIndex(where: { $0.id == id }), var list = rows {
            // Shown at the end of the pinned rows until the owner's rows come back.
            let row = list.remove(at: index)
            list.insert(row, at: list.firstIndex { !$0.pinned } ?? list.endIndex)
            reply?.rows = list
        }
        write([(id, .pin(on, position: on ? Self.now() : nil))])
    }

    /// This owner's pinned rows at new positions (a drag in the pinned grid; the caller numbers the whole
    /// shown grid, both owners, in its new order). `done` gets the ids the owner accepted.
    public func place(_ positions: [(id: String, position: UInt64)], done: (@MainActor ([String]) -> Void)? = nil) {
        guard var list = rows else { done?([]); return }
        let placed = Set(positions.map(\.id))
        let pinned = positions.compactMap { place in list.first { $0.id == place.id }.map { ($0, place.position) } }.map { row, position in
            var row = row
            row.pinned = true
            row.pinPosition = position
            return row
        }
        list.removeAll { placed.contains($0.id) }
        list.insert(contentsOf: pinned, at: list.firstIndex { !$0.pinned } ?? list.endIndex)
        reply?.rows = list
        write(pinned.map { ($0.id, .pin(true, position: $0.pinPosition)) }, done: done)
    }

    /// Pins `ids` in this order after the person's other pins (the one-time move of this Mac's pins,
    /// `HomePinMigration`); `done` gets the ids the owner accepted.
    public func adopt(pins ids: [String], done: @escaping @MainActor ([String]) -> Void) {
        let base = Self.now()
        place(ids.enumerated().map { (id: $0.element, position: base + UInt64($0.offset)) }, done: done)
    }

    /// Marks `id` unread (Mark as Unread) or clears the mark; nothing is sent when it already is so.
    public func setMarkedUnread(_ on: Bool, _ id: String) {
        guard let row = rows?.first(where: { $0.id == id }), row.markedUnread != on else { return }
        edit(id) { $0.markedUnread = on }
        write([(id, .markUnread(on))])
    }

    /// Hide Alerts (`on`) or Show Alerts for a Cloud row (`inbox.mute`); a local row has no mute.
    /// Nothing is sent when it already is so.
    public func setMuted(_ on: Bool, _ id: String) {
        guard isCloud, let row = rows?.first(where: { $0.id == id }), (row.muted ?? false) != on else { return }
        edit(id) { $0.muted = on }
        write([(id, .mute(on))])
    }

    /// Whether this source can mute `id` (a Cloud row it lists).
    public func canMute(_ id: String) -> Bool { isCloud && rows?.contains { $0.id == id } == true }

    private func edit(_ id: String, _ change: (inout HomeInboxRequest.Row) -> Void) {
        guard var list = rows, reply != nil, let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        reply?.rows = list
    }

    /// Sends the ops in order, then reads the rows again (the owner's answer wins over the local edit).
    /// Local rows go to `conversation-inbox-op`, Cloud rows to `cloud-inbox-op`. `done` gets the ids of
    /// the ops the owner accepted.
    private func write(_ ops: [(String, ConversationInboxOpRequest.Op)], done: (@MainActor ([String]) -> Void)? = nil) {
        guard let connection, !ops.isEmpty else { done?([]); return }
        pendingWrites += 1
        let cloud = isCloud
        // task-owner: one batch of inbox ops; ends with the last reply
        Task { [weak self] in
            var accepted: [String] = []
            for (id, op) in ops {
                let sent = if cloud {
                    (try? await connection.request(CloudInboxOpRequest(conversation: id, op: op))) != nil
                } else {
                    (try? await connection.request(ConversationInboxOpRequest(conversation: id, op: op))) != nil
                }
                if sent { accepted.append(id) }
            }
            done?(accepted)
            guard let self else { return }
            pendingWrites -= 1
            if pendingWrites == 0 { refresh() }
        }
    }

    /// Milliseconds since 1970: the position the Channels page gives a pin too, so both views'
    /// pins sort by when they were made.
    static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}
