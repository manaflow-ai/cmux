public import Foundation
public import Observation

/// The home session's sidebar document as this app shows it
/// (`sidebar-doc-v1`). The daemon owns the document; this store keeps the
/// client mirror (`SidebarMirror`: confirmed document plus pending intents,
/// ordered and judged by the Rust reducer) and the records the rows draw.
/// Every move is one intent: applied to the mirror at once, sent as one
/// `sidebar.move` (or pin, unpin, apply) with an idempotency key, settled
/// by the daemon's echoed batch, and undone with the inverse the daemon
/// returns (one undo entry per move). A batch whose revision skips one
/// refetches the document.
@Observable @MainActor
public final class SidebarDocStore {
    /// The records of the confirmed document.
    public private(set) var records = SidebarDocRecords()
    /// Changes whenever what the sidebar draws may have changed (a load, a
    /// batch, an intent): the bridge rebuilds its rows on it.
    public private(set) var version: UInt64 = 0
    /// Moves when a batch folded or opened groups and changed nothing else
    /// (`lastFolds`): no row is rebuilt for a fold, each window applies it to
    /// its own rows (plans/cmux-next/state-ownership-DESIGN.md).
    public private(set) var foldRevision: UInt64 = 0
    /// The groups the last fold-only batch folded (id to `collapsed`).
    @ObservationIgnored public private(set) var lastFolds: [String: Bool] = [:]
    /// Each group's confirmed fold, read without observation: the sidebar maps a group's
    /// `collapsed` from it, so a fold's echo rebuilds nothing (`SidebarDocProjection` keeps the
    /// fold it was built with).
    @ObservationIgnored public private(set) var groupFolds: [String: Bool] = [:]
    /// The document is loaded and the daemon serves it: the sidebar draws
    /// it. False keeps the older path.
    public private(set) var isActive = false
    /// What the sidebar draws from the document (`show(live:)`); nil while inactive.
    public internal(set) var shown: SidebarDocProjection?
    /// The `version` `shown` was built at: behind `version` while an applied change (a Cmd-N move) waits for the next
    /// `show`, a hop later.
    @ObservationIgnored public internal(set) var shownVersion: UInt64 = 0

    @ObservationIgnored private let mirror: SidebarMirror?
    @ObservationIgnored private let remote: (any SidebarDocRemote)?
    /// A refusal or failure to show (the refusal HUD).
    @ObservationIgnored public var onRefused: @MainActor (String) -> Void = { _ in }
    /// Posted when a change was refused (by the mirror or the daemon), with its `key` in userInfo:
    /// a list holding that drop's look lets it go.
    nonisolated public static let refusedNotification = Notification.Name("cmux.sidebar.docRefused")
    /// Posted when a change changed nothing (a no-op move echoes no batch), with its `key`: a list holding its look lets it go.
    nonisolated public static let settledNotification = Notification.Name("cmux.sidebar.docSettled")
    /// The idempotency key of the last change sent (a list matches a drop's notifications by it).
    public private(set) var lastIntentKey: String?

    /// Tells the App and every list that the change `key` was refused.
    private func refuse(_ message: String, key: String? = nil) {
        NotificationCenter.default.post(name: Self.refusedNotification, object: self, userInfo: ["key": key ?? lastIntentKey ?? ""])
        onRefused(message)
    }
    /// A user's move that can be undone: the title and the undo. The App
    /// puts it on its undo surface (the toast and Cmd-Z).
    /// `origin`: `undoOrigin` when the change was sent (the undo step an undo
    /// or redo put for this inverse), so the App fills that step.
    @ObservationIgnored public var onUndoable: @MainActor (String, AnyObject?, @escaping @MainActor () -> Void) -> Void = { _, _, _ in }
    /// A user's undoable change was sent: the App puts its undo step (and toast) now and returns it; the reply fills it
    /// through `onUndoable` (its `origin`), or `onUndoRefused` takes it away. Nil: the step comes with the reply.
    @ObservationIgnored public var onUndoPending: @MainActor (String) -> AnyObject? = { _ in nil }
    /// The change sent for `origin` gave no undoable inverse (refused, or a no-op): its step stays empty.
    @ObservationIgnored public var onUndoRefused: @MainActor (AnyObject) -> Void = { _ in }
    /// Set by the App around running an undo step's inverse; each change sent meanwhile carries it to `onUndoable`.
    @MainActor public static var undoOrigin: AnyObject?
    @ObservationIgnored private var loading = false
    /// A refetch asked for while one was in flight runs after it.
    @ObservationIgnored private var refetchAgain = false
    /// Batches that arrived while the first load was in flight; applied after it (the mirror drops the stale ones).
    @ObservationIgnored private var earlyBatches: [Data] = []
    /// The live workspaces and the connected other machines at the last `show` (a remote close is a live ref that left).
    @ObservationIgnored var lastLive: Set<SidebarDocWorkspaceRef> = []
    @ObservationIgnored var lastConnectedRemotes: Set<String> = []
    /// The page icon address last sent for each url item (`storeIconURLs` sends each one once).
    @ObservationIgnored var requestedIconURLs: [String: String] = [:]
    /// The last projection (`projection(live:)`), with what it was built over.
    @ObservationIgnored var projectionCache: SidebarDocProjectionCache?
    /// Changes whose outcome no reply told (all asks unanswered, or answered only after an ask went unanswered: the
    /// echo may have gone to a closed connection). They stay pending until the next document load, which says where
    /// the rows really are: the load drops them (cx-ml98q).
    @ObservationIgnored private var unanswered: Set<String> = []
    /// Loads failed in a row while unanswered changes wait (a `sidebar.get` that timed out under the same load).
    @ObservationIgnored private var failedLoads = 0
    /// Refs already sent to `sidebar.adopt` this session.
    @ObservationIgnored private var adopting: Set<SidebarDocWorkspaceRef> = []
    /// What to run when a fold (`setGroupCollapsed`) is refused, by its key.
    @ObservationIgnored private var foldRefusals: [String: @MainActor () -> Void] = [:]
    /// What pending changes write on records (a group's name, color, icon; a new group), drawn over `records` (#26382).
    @ObservationIgnored private var pendingRecords = SidebarDocPendingRecords()

    /// The records the rows draw: the confirmed ones with the pending changes' writes (`SidebarDocPendingRecords`).
    public var shownRecords: SidebarDocRecords { pendingRecords.isEmpty ? records : pendingRecords.applied(to: records) }

    /// The app's one document store (one home session per app); the
    /// App's composition root sets it.
    public static var current: SidebarDocStore?
    /// The records of the current document while the sidebar draws it; nil on the older path.
    public static var activeRecords: SidebarDocRecords? { current.flatMap { $0.isActive && $0.shown != nil ? $0.records : nil } }

    public init(remote: (any SidebarDocRemote)?, mirror: SidebarMirror? = SidebarMirror.make()) {
        self.remote = remote
        self.mirror = mirror
    }

    /// Whether this build and the daemon can use the document at all.
    public var isSupported: Bool { mirror != nil && (remote?.isAvailable ?? false) }

    // MARK: Following the daemon

    /// Fetches the whole document (the first load, a reconnect, a stream
    /// snapshot, a revision gap).
    public func refresh() {
        if loading { refetchAgain = true; return }
        guard isSupported, let remote, let mirror else {
            if isActive, !isSupported { isActive = false; shown = nil; bump() }
            return
        }
        loading = true
        // The load answers the changes unanswered before it was asked for (a later one asks for another load), and holds
        // the changes answered before it was asked for: a change answered while it is on the way may not be in it.
        let answering = unanswered, held = pendingRecords.replied
        // task-owner: one sidebar.get; settles the load
        Task { [weak self] in
            defer {
                self?.loading = false
                if self?.refetchAgain == true { self?.refetchAgain = false; self?.refresh() }
            }
            guard let data = try? await remote.get(), let records = try? SidebarDocRecords(document: data), let self,
                  mirror.load(data) else {
                // Unanswered changes wait for a load: ask again (a bounded number of times; a reconnect loads anyway).
                if let self, !answering.isEmpty, self.failedLoads < Self.unsettledAsks {
                    self.failedLoads += 1
                    self.refetchAgain = true
                }
                return
            }
            self.failedLoads = 0
            // The document has each unanswered change or never will: it shows as loaded (no replay on top).
            for key in answering {
                mirror.reject(key)
                self.pendingRecords.remove(key)
            }
            // The document holds the changes answered before the load was asked for (or never will): their rows draw it.
            for key in held { self.pendingRecords.remove(key) }
            self.unanswered.subtract(answering)
            self.records = records
            self.groupFolds = records.items.compactMapValues(\.body.groupCollapsed)
            self.isActive = true
            self.bump()
            let early = self.earlyBatches
            self.earlyBatches = []
            for batch in early { self.receive(batch: batch) }
        }
    }

    /// One `session.events` batch of document changes (JSON, with its
    /// revision and idempotency key).
    public func receive(batch data: Data) {
        guard isActive, let mirror else {
            if loading, mirror != nil, earlyBatches.count < 512 { earlyBatches.append(data) }
            return
        }
        // The mirror drops the pending intent with the batch's key in every case: so do its record writes.
        let settled = !pendingRecords.isEmpty && SidebarDocWire.Batch.key(of: data).map { pendingRecords.remove($0) } == true
        // The reducer judges the revision chain: a skipped one refetches.
        switch mirror.apply(batch: data) {
        case .stale:
            if settled { bump() }
        case .refetch: return refresh()
        case .applied(let revision):
            let folds = records.apply(batch: data)
            if let revision { records.revision = revision }
            guard let folds, !settled else {
                groupFolds = records.items.compactMapValues(\.body.groupCollapsed)
                return bump()
            }
            // Folds only: the windows fold their own rows (`foldRevision`); nothing is rebuilt.
            groupFolds.merge(folds) { _, new in new }
            lastFolds = folds
            foldRevision &+= 1
        }
    }

    /// Asks the daemon to place live workspaces the document lacks (each once).
    public func adopt(_ refs: [SidebarDocWorkspaceRef]) {
        let fresh = refs.filter { !adopting.contains($0) }
        guard isActive, !fresh.isEmpty, let remote else { return }
        adopting.formUnion(fresh)
        // task-owner: one sidebar.adopt; its batch places the rows. A failed adopt is
        // tried again on the next structural change.
        Task { [weak self] in
            if (try? await remote.adopt(fresh, key: Self.newKey())) == nil { self?.adopting.subtract(fresh) }
        }
    }

    // MARK: Reading

    /// The rows to draw, in order (one FFI call; only on a structural rebuild).
    public func rows(_ request: SidebarViewRequest) -> [SidebarDocRow]? {
        isActive ? mirror?.rows(request) : nil
    }

    /// Group item `item` sits in Pinned as the sidebar draws it, pending changes included, so a second
    /// Pin/Unpin before the daemon answers undoes the first; nil while the document is not shown. It reads
    /// the projection over the live set `show` used, so the mirror's rows (a drag reads them) stay as shown.
    public func showsPinned(group item: String) -> Bool? {
        guard isActive, shown != nil else { return nil }
        let projection = projection(live: projectionCache?.live ?? Array(lastLive))
        return projection.map { $0.bandGroups.contains { $0.id == item && $0.pinned } } ?? records.isPinned(group: item)
    }

    /// What a drop of `items` may do beside each row (one FFI call per drag).
    /// Pinned takes only what is pinned already (`SidebarDocRecords.keepingPinned`).
    public func acceptance(dragging items: [String]) -> [String: SidebarDocAcceptance] {
        isActive ? records.keepingPinned(mirror?.acceptance(dragging: items) ?? [:], dragging: items) : [:]
    }

    nonisolated public static let pinnedSection = "sec_pinned"
    /// A machine section's id is this prefix and the machine's session (the reducer's `machine_section_id`).
    nonisolated public static let machineSectionPrefix = "sec_m_"

    // MARK: Intents

    /// Moves `items` to `target` as one change and one undo step titled `title`.
    public func move(_ items: [String], to target: SidebarDocTarget, title: String) {
        guard !items.isEmpty else { return } // nothing placed yet to move (an adopt is on the way)
        send(.move(items, to: target, key: Self.newKey()), title: title) { remote, key, _ in
            try await remote.move(items, to: target, key: key)
        }
    }

    /// Pin: the items move to the end of Pinned.
    public func pin(_ items: [String], title: String) {
        guard !items.isEmpty else { return } // nothing placed yet to move (an adopt is on the way)
        send(.pin(items, key: Self.newKey()), title: title) { remote, key, _ in
            try await remote.pin(items, key: key)
        }
    }

    /// Unpin: each item moves to the end of its own machine section.
    public func unpin(_ items: [String], title: String) {
        guard !items.isEmpty else { return } // nothing placed yet to move (an adopt is on the way)
        send(.unpin(items, key: Self.newKey()), title: title) { remote, key, _ in
            try await remote.unpin(items, key: key)
        }
    }

    /// Archive (`archived` true): each item moves to the end of its own list (its group, or its
    /// section's top level) and draws dimmed. Unarchive puts it back where it was archived from
    /// (plans/cmux-next/archiving-DESIGN.md). One undo step titled `title`. Throws the reducer's
    /// refusal (a provider-owned section, an unknown item), so the CLI and MCP get it too.
    public func setArchived(_ items: [String], archived: Bool, title: String) throws(SidebarDocSendRefusal) {
        guard !items.isEmpty else { return } // nothing placed yet (an adopt is on the way)
        try sendChecked(ops: [["op": archived ? "archive" : "unarchive", "items": items]], title: title)
    }

    /// Folds or opens `group` in the document (the owner of record; other clients follow it). The
    /// sidebar already shows the fold (it is view state the window applies at once): this sends one
    /// `group.update` with the value, not a toggle, so fast clicks each send what they show, and it
    /// rebuilds no row, now or at the echo. `refused` runs when the daemon or the mirror refuses it.
    public func setGroupCollapsed(_ group: String, _ collapsed: Bool, refused: @escaping @MainActor () -> Void) {
        let ops: [[String: Any]] = [["op": "group.update", "id": Self.item(group: GroupID(group), in: records), "patch": ["collapsed": collapsed]]]
        guard let data = try? JSONSerialization.data(withJSONObject: ops) else { return refused() }
        let intent = SidebarMirrorIntent.apply(data, key: Self.newKey())
        foldRefusals[intent.idempotencyKey] = refused
        do {
            try submit(intent, title: Self.moveTitle, undoable: false, redraws: false) { remote, key, stamped in
                try await remote.apply(ops: stamped ?? data, key: key)
            }
        } catch {
            foldRefusals[intent.idempotencyKey] = nil
            refused()
        }
    }

    /// Sends reducer ops (`[{op: ...}]`, JSON objects) as one `sidebar.apply`:
    /// group edits, adopt-then-move. `undoable` false (a collapse) puts no undo step.
    public func send(ops: [[String: Any]], title: String, undoable: Bool = true) {
        guard !ops.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ops) else { return }
        send(.apply(data, key: Self.newKey()), title: title, undoable: undoable) { remote, key, stamped in
            try await remote.apply(ops: stamped ?? data, key: key)
        }
    }

    /// Applies ops the daemon returned as an inverse (undo, then redo).
    private func apply(_ ops: Data, title: String) {
        send(.apply(ops, key: Self.newKey()), title: title) { remote, key, stamped in
            try await remote.apply(ops: stamped ?? ops, key: key)
        }
    }

    /// Like `send(ops:title:undoable:)`, but a change refused at once (the
    /// document is not active, or the mirror's reducer refuses it) throws
    /// its message instead of showing it, so an automation caller gets the
    /// error. A later daemon refusal still shows in the refusal HUD.
    public func sendChecked(ops: [[String: Any]], title: String, undoable: Bool = true) throws(SidebarDocSendRefusal) {
        guard !ops.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ops) else { return }
        try submit(.apply(data, key: Self.newKey()), title: title, undoable: undoable) { remote, key, stamped in
            try await remote.apply(ops: stamped ?? data, key: key)
        }
    }

    private func send(_ intent: SidebarMirrorIntent, title: String, undoable: Bool = true,
                      _ body: @escaping @MainActor (any SidebarDocRemote, String, Data?) async throws -> SidebarDocReply) {
        do {
            try submit(intent, title: title, undoable: undoable, body)
        } catch {
            if let origin = Self.undoOrigin { onUndoRefused(origin) }
            onRefused(error.message)
        }
    }

    /// Applies `intent` to the mirror and sends it; throws (after telling every list) when it is refused at once.
    /// `redraws` false (a fold): the rows the mirror orders do not change, so no rebuild follows the intent.
    private func submit(_ intent: SidebarMirrorIntent, title: String, undoable: Bool, redraws: Bool = true,
                        _ body: @escaping @MainActor (any SidebarDocRemote, String, Data?) async throws -> SidebarDocReply) throws(SidebarDocSendRefusal) {
        lastIntentKey = intent.idempotencyKey
        func refused(_ message: String) -> SidebarDocSendRefusal {
            NotificationCenter.default.post(name: Self.refusedNotification, object: self, userInfo: ["key": intent.idempotencyKey])
            return SidebarDocSendRefusal(message: message)
        }
        guard isActive, let mirror, let remote else { throw refused(SidebarDocStrings.unavailable) }
        let stamped: Data?
        do {
            stamped = try mirror.apply(intent: intent)
        } catch let refusal as SidebarMirror.Refusal {
            throw refused(SidebarDocStrings.refused(refusal.code))
        } catch {
            throw refused(SidebarDocStrings.unavailable)
        }
        let key = intent.idempotencyKey
        // A rename, recolor or new group draws from its records: they show with the rows, not at the echo (#26382).
        pendingRecords.add(key: key, ops: stamped ?? intent.ops, records: shownRecords)
        if redraws { bump() }
        // An undo's or redo's inverse fills the step the undo put; a user's change puts its own step now (cx-kpicb).
        let origin = Self.undoOrigin ?? (undoable ? onUndoPending(title) : nil)
        // task-owner: one sidebar mutation; settles its pending intent
        Task { [weak self] in
            // wakeup-allow: bounded retry only after an awaited remote call; this is not polling.
            // Each ask either returns or, unanswered before the last one, asks again: at most `unsettledAsks` sends.
            for asked in 1...Self.unsettledAsks {
                do {
                    let reply = try await body(remote, key, stamped)
                    guard let self else { return }
                    // Answered only after an unanswered ask: the daemon replays a committed change without a new
                    // echo, and the first echo may have gone to a closed connection. The next load settles the key.
                    if asked > 1 { self.settleByLoad(key) }
                    self.foldRefusals[key] = nil
                    self.pendingRecords.noteReplied(key)
                    // A no-op change echoes no batch: its intent must not stay pending.
                    if !reply.hasInverse {
                        self.drop(key, redraws: redraws)
                        NotificationCenter.default.post(name: Self.settledNotification, object: self, userInfo: ["key": key])
                    }
                    if undoable, reply.hasInverse {
                        let inverse = reply.inverse
                        self.onUndoable(title, origin) { [weak self] in self?.apply(inverse, title: title) }
                    } else if let origin {
                        self.onUndoRefused(origin)
                    }
                    return
                } catch is SidebarDocUnsettled where asked < Self.unsettledAsks {
                    // No reply (a timeout under load, a lost connection): the daemon may have applied the change, and
                    // its echo may still come. The intent stays pending, so the rows keep the optimistic look; the
                    // same key asks again and the daemon replays a committed change (cx-ml98q: a timed-out drop flew
                    // back to its source, then the late echo moved it again).
                    continue
                } catch {
                    guard let self else { return }
                    if let origin { self.onUndoRefused(origin) }
                    if error is SidebarDocUnsettled {
                        // Never answered: the daemon may have the change. The rows keep the optimistic look until the
                        // next load shows the document (the change stays, or the rows spring back once).
                        // A fold stops holding its look: the load shows the document's fold.
                        self.foldRefusals.removeValue(forKey: key)?()
                        self.settleByLoad(key)
                        return
                    }
                    // The daemon refused it: no batch will echo the key. The rows spring back once.
                    self.foldRefusals.removeValue(forKey: key)?()
                    self.drop(key)
                    self.refuse(SidebarDocStrings.describe(error), key: key)
                    return
                }
            }
        }
    }

    /// How many times one change is sent under its key before an unanswered change counts as refused.
    private static let unsettledAsks = 4

    /// `key`'s outcome is not known from a reply: the next document load settles it (now, or after a reconnect).
    private func settleByLoad(_ key: String) {
        unanswered.insert(key)
        refresh()
    }

    private func drop(_ key: String, redraws: Bool = true) {
        mirror?.reject(key)
        if pendingRecords.remove(key) || redraws { bump() }
    }

    private func bump() { version &+= 1 }

    static func newKey() -> String { "sidebar-" + UUID().uuidString.lowercased() }
}

/// A change sent with no answer (a timeout, a closed connection): the daemon may have applied it. The store sends it
/// again under the same idempotency key (the daemon replays a committed change) instead of dropping it.
public nonisolated struct SidebarDocUnsettled: Error, Hashable, Sendable {
    public init() {}
}

/// A change refused before it was sent, with the message the refusal HUD shows.
public nonisolated struct SidebarDocSendRefusal: Error, Hashable, Sendable {
    public var message: String
}

/// The daemon side of the document (the App's home daemon connection).
@MainActor
public protocol SidebarDocRemote: AnyObject {
    /// The home daemon is connected and serves `sidebar-doc-v1`.
    var isAvailable: Bool { get }
    /// `sidebar.get`, as JSON.
    func get() async throws -> Data
    func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply
    func pin(_ items: [String], key: String) async throws -> SidebarDocReply
    func unpin(_ items: [String], key: String) async throws -> SidebarDocReply
    func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply
    /// `sidebar.apply {ops}`; `ops` is a JSON array.
    func apply(ops: Data, key: String) async throws -> SidebarDocReply
}

/// A mutation's reply: the revision after it and its inverse ops (a JSON array).
public nonisolated struct SidebarDocReply: Hashable, Sendable {
    public var revision: UInt64?
    public var inverse: Data

    public init(revision: UInt64?, inverse: Data) {
        self.revision = revision
        self.inverse = inverse
    }

    /// The inverse holds at least one op.
    public var hasInverse: Bool {
        guard let ops = try? JSONSerialization.jsonObject(with: inverse) as? [Any] else { return false }
        return !ops.isEmpty
    }
}
