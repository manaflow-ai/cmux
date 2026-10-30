public import Foundation
public import Observation

/// The app's windows over acpmux's chat index (`_acpmux/chats_window`, P-RUST 2026-10-30).
///
/// acpmux owns the chat list: its order, filter, exclusions and paging. A native list here names
/// its window (``Spec``) and holds only that window's rows, as value snapshots; acpmux sends the
/// rows, then one row diff per change: the window's keys in order and only the rows whose value
/// changed, with the next revision. Applying a diff on the main actor is O(window keys + changed
/// rows), whatever the index holds (the old whole-index mirror copied and compared every chat per
/// change: hangs of 570 to 1,148 ms, v2.2.9). Diffs are decoded off the main actor.
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

        public init(window: String, limit: Int, topLevel: Bool = true, exclude: [String] = [], keys: [String]? = nil) {
            self.window = window
            self.limit = limit
            self.topLevel = topLevel
            self.exclude = exclude
            self.keys = keys
        }

        public var params: [String: any Sendable] {
            var params: [String: any Sendable] = ["window": window, "limit": max(1, limit), "topLevel": topLevel]
            if !exclude.isEmpty { params["exclude"] = exclude }
            if let keys { params["keys"] = keys }
            return params
        }
    }

    /// One window's rows, newest first (or in its keys' order).
    @MainActor @Observable
    public final class Window {
        public private(set) var rows: [AcpmuxChat] = []
        /// More chats pass the window's filter past its rows.
        public private(set) var hasMore = false
        /// The revision of the last message applied; 0 before the first.
        @ObservationIgnored public fileprivate(set) var revision: UInt64 = 0

        fileprivate func set(rows: [AcpmuxChat], hasMore: Bool) {
            if self.rows != rows { self.rows = rows }
            if self.hasMore != hasMore { self.hasMore = hasMore }
        }
    }

    /// One decoded `_acpmux/chats_window_changed` (decoded off the main actor).
    public nonisolated struct Update: Sendable, Equatable {
        public var window: String
        public var revision: UInt64
        /// Every row of the window; false: only the rows whose value changed.
        public var full: Bool
        public var keys: [String]
        public var rows: [String: AcpmuxChat]
        public var hasMore: Bool

        public init(window: String, revision: UInt64, full: Bool, keys: [String], rows: [AcpmuxChat], hasMore: Bool) {
            self.window = window
            self.revision = revision
            self.full = full
            self.keys = keys
            self.rows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            self.hasMore = hasMore
        }

        public init?(params: [String: Any]) {
            guard let window = params["window"] as? String, let revision = (params["revision"] as? NSNumber)?.uint64Value,
                  let keys = params["keys"] as? [String] else { return nil }
            let rows = (params["rows"] as? [[String: Any]] ?? []).compactMap(AcpmuxChat.init(json:))
            self.init(window: window, revision: revision, full: params["full"] as? Bool ?? false, keys: keys, rows: rows,
                      hasMore: params["hasMore"] as? Bool ?? false)
        }
    }

    /// Sends one request to acpmux (`method`, `params`); nil while there is no connection.
    private var send: (@MainActor (String, [String: any Sendable]) -> Void)?
    private var specs: [String: Spec] = [:]
    private var models: [String: Window] = [:]
    /// Windows asked for again: their diffs are ignored until the full message comes.
    private var awaitingFull: Set<String> = []
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
        _ = window(spec.window)
        awaitingFull.remove(spec.window)
        ask(spec)
    }

    /// Closes window `id`: its rows empty.
    public func close(_ id: String) {
        guard specs.removeValue(forKey: id) != nil else { return }
        awaitingFull.remove(id)
        models[id]?.set(rows: [], hasMore: false)
        send?("_acpmux/chats_window_close", ["window": id])
    }

    /// A connection to acpmux is up: every open window is asked again (a new daemon numbers its
    /// revisions from the start, and its first message for each window is full).
    public func connected(send: @escaping @MainActor (String, [String: any Sendable]) -> Void) {
        self.send = send
        for model in models.values { model.revision = 0 }
        resync()
    }

    /// The connection is gone: windows keep their rows until the next one answers.
    public func disconnected() {
        send = nil
    }

    /// The connection dropped a notification (`_acpmux/lagged`): every window is asked again.
    public func resync() {
        awaitingFull = []
        for spec in specs.values.sorted(by: { $0.window < $1.window }) { ask(spec) }
    }

    /// Applies one window message: O(keys + changed rows). A diff that does not follow the last
    /// revision, or names a row this window never got, asks for the window again.
    public func apply(_ update: Update) { // perf-hot: 1ms chats-window-diff (every chat index change a window shows)
        guard let spec = specs[update.window], let model = models[update.window] else { return }
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
        model.set(rows: rows, hasMore: update.hasMore)
    }

    /// Asks for `spec`'s whole window, once until it comes.
    private func ask(_ spec: Spec) {
        guard let send, awaitingFull.insert(spec.window).inserted else { return }
        send("_acpmux/chats_window", spec.params)
    }
}
