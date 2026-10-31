public import Foundation
public import Observation

/// The app's windows over acpmux's chat index (`_acpmux/chats_window`, P-RUST 2026-10-30).
///
/// acpmux owns the chat list: its order, filter, exclusions and paging. A native list here names
/// its window (``Spec``) and holds only that window's rows, as value snapshots; acpmux sends the
/// rows, then one row diff per change: the window's keys in order and only the rows whose value
/// changed, with the next revision. Applying a diff on the main actor is O(window keys + changed
/// rows), whatever the index holds (the old whole-index mirror copied and compared every chat per
/// change on the main actor). Diffs are decoded off the main actor.
///
/// Each spec sent names the window's next generation (`gen`): acpmux refuses an older one and
/// echoes it in every message, so requests that run out of order never leave a window on an older
/// spec, and a message for an older spec is never applied.
///
/// Each window is its own observable object: a view that reads one window updates only when that
/// window's rows change, and a window whose rows did not change sets nothing.
@MainActor
public final class AcpmuxChatWindows {
    /// What a window shows (the `_acpmux/chats_window` params).
    public nonisolated struct Spec: Sendable, Equatable {
        public var window: String
        public var limit: Int
        /// Leaves out a chat another chat's agent started (it folds under that chat).
        public var topLevel: Bool
        public var exclude: [String]
        /// Exactly these chats, in this order (a pinned list); nil: the newest chats.
        public var keys: [String]?
        /// What acpmux ranks the chats by, with the palette's own ranker (title, folder and
        /// harness; every word anywhere); nil or empty: the newest chats.
        public var query: String?
        /// The title a chat with none shows, so a query finds it by that word.
        public var untitled: String?
        /// The person's choice history for these chats (the palette ranker's `{now, frecency}`
        /// JSON), so acpmux ranks a chat chosen before as the palette did.
        public var history: String?
        /// acpmux reports how many chats the window could show in all (`Window.total`).
        public var count: Bool

        public init(window: String, limit: Int, topLevel: Bool = true, exclude: [String] = [], keys: [String]? = nil,
                    query: String? = nil, untitled: String? = nil, history: String? = nil, count: Bool = false) {
            self.untitled = untitled
            self.history = history
            self.count = count
            self.window = window
            self.limit = limit
            self.topLevel = topLevel
            self.exclude = exclude
            self.keys = keys
            self.query = query
        }

        /// The New Tab cards' window over acpmux's index: its newest top-level chats, no more than the cards show.
        public static let newTabCards = Spec(window: "newtab.cards", limit: AgentPaneDeviceChat.maximumPushed, topLevel: true)

        /// The request's params for generation `generation` of the window's spec.
        func params(generation: UInt64) -> [String: any Sendable] {
            var params: [String: any Sendable] = ["window": window, "gen": generation, "limit": max(1, limit), "topLevel": topLevel]
            if !exclude.isEmpty { params["exclude"] = exclude }
            if let keys { params["keys"] = keys }
            if let query, !query.isEmpty { params["query"] = query }
            if let untitled { params["untitled"] = untitled }
            if let history { params["history"] = history }
            if count { params["count"] = true }
            return params
        }
    }

    /// One window's rows, newest first (or in its keys' order).
    @MainActor @Observable
    public final class Window {
        public private(set) var rows: [AcpmuxChat] = []
        /// How many chats matched a query window's query, or a counted window could show (more than
        /// `rows` when it shows a page).
        public private(set) var total: Int?
        /// The revision of the last message applied; 0 before the first.
        @ObservationIgnored public fileprivate(set) var revision: UInt64 = 0
        /// Called with the rows after each message of this window acpmux sends for its current spec
        /// (its first rows, then each diff), for a reader that is not a view (the New Tab page's
        /// cards, the palette's chats page): only this window's messages call it.
        @ObservationIgnored private var followers: [(owner: () -> AnyObject?, changed: @MainActor ([AcpmuxChat]) -> Void)] = []

        /// Called when acpmux will not answer this window's current request (it refused it, busy, or the
        /// connection dropped while it was in flight), while their owner lives.
        @ObservationIgnored private var refusals: [(owner: () -> AnyObject?, refused: @MainActor () -> Void)] = []

        /// Calls `changed` with the rows after each message of this window, while `owner` lives. Followers whose
        /// owner is gone are dropped here too, so one query per key never grows the list.
        public func follow(_ owner: AnyObject, _ changed: @escaping @MainActor ([AcpmuxChat]) -> Void) {
            followers.removeAll { $0.owner() == nil }
            followers.append(({ [weak owner] in owner }, changed))
        }

        /// Calls `refused` when acpmux will not answer this window's current request, while `owner` lives.
        public func followRefusal(_ owner: AnyObject, _ refused: @escaping @MainActor () -> Void) {
            refusals.removeAll { $0.owner() == nil }
            refusals.append(({ [weak owner] in owner }, refused))
        }

        fileprivate func refused() {
            refusals.removeAll { $0.owner() == nil }
            for refusal in refusals { refusal.refused() }
        }

        fileprivate func set(rows: [AcpmuxChat], total: Int? = nil) {
            if self.total != total { self.total = total }
            if self.rows != rows { self.rows = rows }
        }

        fileprivate func answered() {
            followers.removeAll { $0.owner() == nil }
            for follower in followers { follower.changed(rows) }
        }
    }

    /// One decoded `_acpmux/chats_window_changed` (decoded off the main actor).
    public nonisolated struct Update: Sendable, Equatable {
        public var window: String
        /// The generation of the spec it answers; nil from a daemon that names none.
        public var generation: UInt64?
        public var revision: UInt64
        /// Every row of the window; false: only the rows whose value changed.
        public var full: Bool
        public var keys: [String]
        public var rows: [String: AcpmuxChat]
        /// How many chats matched, or a counted window could show.
        public var total: Int?

        public init(window: String, generation: UInt64? = nil, revision: UInt64, full: Bool, keys: [String], rows: [AcpmuxChat]) {
            self.window = window
            self.generation = generation
            self.revision = revision
            self.full = full
            self.keys = keys
            self.rows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            total = nil
        }

        public init?(params: [String: Any]) {
            guard let window = params["window"] as? String, let revision = (params["revision"] as? NSNumber)?.uint64Value,
                  let keys = params["keys"] as? [String] else { return nil }
            let rows = (params["rows"] as? [[String: Any]] ?? []).compactMap(AcpmuxChat.init(json:))
            self.init(window: window, generation: (params["gen"] as? NSNumber)?.uint64Value, revision: revision,
                      full: params["full"] as? Bool ?? false, keys: keys, rows: rows)
            total = (params["total"] as? NSNumber)?.intValue
        }
    }

    /// Sends one request to acpmux (`method`, `params`); nil while there is no connection.
    private var send: (@MainActor (String, [String: any Sendable]) -> Void)?
    private var specs: [String: Spec] = [:]
    /// Each window's generation: one more per spec the client opens or closes.
    private var generations: [String: UInt64] = [:]
    private var models: [String: Window] = [:]
    /// The generation whose rows each window holds (the last message applied).
    private var answeredGeneration: [String: UInt64] = [:]
    /// Windows asked for again: their diffs are ignored until the full message comes.
    private var awaitingFull: Set<String> = []
    /// Windows whose last request acpmux refused (busy): asked again at the next ``retryFailed()``.
    private var failed: Set<String> = []
    /// Windows whose request acpmux answered `ready: false` (its index has not started): they fill when it does.
    private var notReady: Set<String> = []
    /// Called when acpmux can answer again (``followAvailability(_:_:)``).
    private var availability: [(owner: () -> AnyObject?, changed: @MainActor () -> Void)] = []
    /// The rows the last applied message installed (decoded values taken), for tests and the
    /// debug counters: one changed chat is one row.
    public private(set) var lastTouchedRows = 0

    public init() {}

    /// The window named `id` (empty until acpmux answers its spec).
    public func window(_ id: String) -> Window {
        if let model = models[id] { return model }
        let model = Window()
        models[id] = model
        return model
    }

    /// Opens `spec`'s window, or changes its spec; an unchanged spec sends nothing.
    public func open(_ spec: Spec) {
        guard specs[spec.window] != spec else { return }
        specs[spec.window] = spec
        generations[spec.window, default: 0] += 1
        _ = window(spec.window)
        awaitingFull.remove(spec.window)
        failed.remove(spec.window)
        ask(spec)
    }

    /// Closes window `id`: its rows empty.
    public func close(_ id: String) {
        guard specs.removeValue(forKey: id) != nil else { return }
        generations[id, default: 0] += 1
        awaitingFull.remove(id)
        failed.remove(id)
        notReady.remove(id)
        models[id]?.set(rows: [])
        send?("_acpmux/chats_window_close", ["window": id, "gen": generations[id] ?? 0])
    }

    /// A connection to acpmux is up: every open window is asked again (a new daemon numbers its
    /// revisions from the start, and its first message for each window is full).
    public func connected(send: @escaping @MainActor (String, [String: any Sendable]) -> Void) {
        self.send = send
        for model in models.values { model.revision = 0 }
        resync()
        becameAvailable()
    }

    /// The connection is gone: windows keep their rows until the next one answers.
    public func disconnected() {
        send = nil
        // A request in flight on the dropped connection gets no answer from it.
        for id in awaitingFull.sorted() { models[id]?.refused() }
    }

    /// Whether a connection to acpmux is up (a window opened now is asked at once).
    public var isConnected: Bool { send != nil }

    /// Whether acpmux refused window `id`'s current request (busy); it is asked again at the next index change.
    public func isRefused(_ id: String) -> Bool { failed.contains(id) }

    /// The connection dropped a notification (`_acpmux/lagged`): every window is asked again.
    public func resync() {
        awaitingFull = []
        failed = []
        for spec in specs.values.sorted(by: { $0.window < $1.window }) { ask(spec) }
    }

    /// acpmux refused the request of generation `generation` of window `id`. A refusal of an older spec than
    /// the window's current one says nothing about the current request, so it is ignored.
    public func requestFailed(_ id: String, generation: UInt64?) {
        guard generation == nil || generation == generations[id] else { return }
        requestFailed(id)
    }

    /// acpmux answered the request of generation `generation` of window `id` with `ready: false`: its index
    /// has not started, and the window fills when it does. Until then the window's request gets no rows, so
    /// its readers end now (as on a refusal) and are told to ask again when the rows come
    /// (``followAvailability(_:_:)``). An older spec's answer is ignored.
    public func requestNotReady(_ id: String, generation: UInt64?) {
        guard specs[id] != nil, generation == nil || generation == generations[id] else { return }
        notReady.insert(id)
        models[id]?.refused()
    }

    /// Calls `changed` when acpmux can answer again (a connection came, or an index that was not ready filled a
    /// window), while `owner` lives.
    public func followAvailability(_ owner: AnyObject, _ changed: @escaping @MainActor () -> Void) {
        availability.removeAll { $0.owner() == nil }
        availability.append(({ [weak owner] in owner }, changed))
    }

    private func becameAvailable() {
        availability.removeAll { $0.owner() == nil }
        for observer in availability { observer.changed() }
    }

    /// acpmux answered window `id`'s request with an error: a busy daemon is asked again at the next
    /// ``retryFailed()`` (the next index change or reconnect), never on a timer.
    public func requestFailed(_ id: String) {
        guard specs[id] != nil else { return }
        awaitingFull.remove(id)
        failed.insert(id)
        models[id]?.refused()
    }

    /// Asks again for every window whose request failed (an index change: the daemon is serving).
    public func retryFailed() {
        guard !failed.isEmpty else { return }
        let retry = failed
        failed = []
        for id in retry.sorted() { if let spec = specs[id] { ask(spec) } }
    }

    /// Applies one window message: O(keys + changed rows). A message for an older spec is dropped;
    /// a diff that does not follow the last revision, or names a row this window never got, asks
    /// for the window again.
    public func apply(_ update: Update) { // perf-hot: 1ms chats-window-diff (every chat index change a window shows)
        guard let spec = specs[update.window], let model = models[update.window] else { return }
        if let generation = update.generation, generation != generations[update.window] { return }
        if update.full {
            awaitingFull.remove(update.window)
        } else {
            guard !awaitingFull.contains(update.window) else { return }
            guard update.revision == model.revision + 1 else { return ask(spec) }
        }
        var known: [String: AcpmuxChat] = [:]
        if !update.full {
            known.reserveCapacity(model.rows.count)
            for row in model.rows { known[row.id] = row }
        }
        var rows: [AcpmuxChat] = []
        rows.reserveCapacity(update.keys.count)
        for key in update.keys {
            guard let row = update.rows[key] ?? known[key] else { return ask(spec) }
            rows.append(row)
        }
        model.revision = update.revision
        lastTouchedRows = update.rows.count
        model.set(rows: rows, total: update.total)
        answeredGeneration[update.window] = generations[update.window]
        model.answered()
        // The index that was not ready filled this window: a reader that ended on `ready: false` asks again.
        if update.full, notReady.remove(update.window) != nil { becameAvailable() }
    }

    /// Whether `spec` is its window's current spec and acpmux answered it (the rows are `spec`'s). A
    /// window asked again (a reconnect, a lag, a broken diff) is not answered until its full answer
    /// comes, nor one whose request acpmux refused: until then its rows are the old connection's.
    public func isAnswered(_ spec: Spec) -> Bool {
        specs[spec.window] == spec && answeredGeneration[spec.window] != nil
            && answeredGeneration[spec.window] == generations[spec.window] && !awaitingFull.contains(spec.window)
            && !failed.contains(spec.window)
    }

    /// Asks for `spec`'s whole window, once until it comes.
    private func ask(_ spec: Spec) {
        guard let send, awaitingFull.insert(spec.window).inserted else { return }
        send("_acpmux/chats_window", spec.params(generation: generations[spec.window] ?? 0))
    }
}
