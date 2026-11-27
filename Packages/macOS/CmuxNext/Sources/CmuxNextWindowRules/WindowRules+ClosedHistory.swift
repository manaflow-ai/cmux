public import CmuxNextDaemon

/// The daemon's closed history as the app reads it and the undo toast's expected closes
/// (cmux-window-rules `closed`).
extension WindowRules {
    /// A closed item's facts as the history rules read them, with its machine.
    public nonisolated struct ClosedFacts: Encodable, Equatable, Sendable {
        struct Tab: Encodable, Equatable, Sendable {
            var kind: String
            var empty: Bool
            var page: Bool
            var url: String?
        }

        var kind: String
        var grouped: Bool
        var tabs: [Tab]
        var machine: String

        public init(_ item: ClosedItem, machine: String) {
            kind = item.kind.rawValue
            grouped = item.group != nil
            tabs = item.tabs.map { Tab(kind: $0.kind, empty: $0.empty, page: $0.page != nil, url: $0.url) }
            self.machine = machine
        }
    }

    /// The rows (indices into `items`, newest first) a closed history list keeps: a page once, at its newest close.
    /// Every row when the FFI does not answer.
    public func newestOnce(_ items: [ClosedFacts]) -> [Int] {
        struct Request: Encodable { var items: [ClosedFacts] }
        struct Reply: Decodable { var keep: [Int] }
        return call("window_close_history_once", Request(items: items), as: Reply.self)?.keep ?? Array(items.indices)
    }

    /// Every close (indices) the row of `items[target]` stands for: each close of its page, else itself.
    public func closes(of target: Int, among items: [ClosedFacts]) -> [Int] {
        struct Request: Encodable { var items: [ClosedFacts], target: Int }
        struct Reply: Decodable { var closes: [Int] }
        return call("window_close_history_closes", Request(items: items, target: target), as: Reply.self)?.closes ?? [target]
    }

    /// What an entry's owner for Cmd-Shift-T reads.
    public nonisolated struct OwnerFacts: Encodable, Equatable, Sendable {
        var kind: String
        var local: Bool
        var recordedWindow: String?
        var recordedOpen: Bool?
        var workspaceWindow: String?

        /// `recordedWindow`: this app's window the item's record names; `recordedOpen`: whether the
        /// registry knows it open (nil: unknown); `workspaceWindow`: the window listing its workspace.
        public init(kind: ClosedItem.Kind, local: Bool, recordedWindow: String?, recordedOpen: Bool?, workspaceWindow: String?) {
            self.kind = kind.rawValue
            self.local = local
            self.recordedWindow = recordedWindow
            self.recordedOpen = recordedOpen
            self.workspaceWindow = workspaceWindow
        }
    }

    /// Cmd-Shift-T's entry (index into `entries`, newest first) for `window`: the newest that left it,
    /// else the newest no live window owns.
    public func newestClosed(_ entries: [OwnerFacts], window: String?) -> Int? {
        struct Request: Encodable { var entries: [OwnerFacts], window: String? }
        return call("window_close_history_newest", Request(entries: entries, window: window), as: Index.self)?.index
    }

    /// The undo toast's gestures waiting for their closed items; the app keeps it between calls.
    public nonisolated struct UndoState: Codable, Equatable, Sendable {
        struct Tab: Codable, Equatable, Sendable {
            var id: String
            var index: Int
        }

        struct Expected: Codable, Equatable, Sendable {
            var token: UInt64
            var tabs: [Tab]
            var panes: [String]
            var costly: Bool
            var items: [String]
            var recorded: Int
        }

        var expected: [Expected] = []

        public init() {}

        /// Each waiting gesture's panes, tab count and recorded tabs (`debug.filepages`).
        public var waiting: [(panes: [String], tabs: Int, recorded: Int)] {
            expected.map { ($0.panes, $0.tabs.count, $0.recorded) }
        }
    }

    /// What announcing a gesture did.
    public nonisolated enum Announced: Equatable, Sendable {
        /// No closing tab was found.
        case empty
        /// A tab of it still waits (a repeated Cmd-W): the same gesture.
        case repeated
        /// It waits; `dropped` are the oldest gestures past the limit.
        case waiting(dropped: [UInt64])
    }

    /// A user's close of `tabs` (id, place before the close) from `panes` in one gesture named `token`.
    /// Nil when the FFI does not answer (nothing waits).
    public func expectClose(_ state: UndoState, token: UInt64, tabs: [(id: String, index: Int)], panes: [String],
                            costly: Bool) -> (state: UndoState, announced: Announced)? {
        struct Request: Encodable { var state: UndoState, token: UInt64, tabs: [UndoState.Tab], panes: [String], costly: Bool }
        struct Outcome: Decodable { var outcome: String, dropped: [UInt64]? }
        struct Reply: Decodable { var state: UndoState, announced: Outcome }
        let request = Request(state: state, token: token, tabs: tabs.map { UndoState.Tab(id: $0.id, index: $0.index) }, panes: panes, costly: costly)
        guard let reply = call("window_close_undo_expect", request, as: Reply.self) else { return nil }
        let announced: Announced = switch reply.announced.outcome {
        case "empty": .empty
        case "repeated": .repeated
        default: .waiting(dropped: reply.announced.dropped ?? [])
        }
        return (reply.state, announced)
    }

    /// A closed item the daemon recorded since the last call.
    public nonisolated struct RecordedItem: Encodable, Equatable, Sendable {
        var id: String
        var kind: String
        var pane: String?
        var tabs: Int

        public init(id: String, kind: ClosedItem.Kind?, pane: String?, tabs: Int) {
            self.id = id
            self.kind = kind?.rawValue ?? "other"
            self.pane = pane
            self.tabs = tabs
        }
    }

    /// A gesture whose every record is in.
    public nonisolated struct Settled: Decodable, Equatable, Sendable {
        public var token: UInt64
        /// Its closed items, in the order recorded (reopen the last first).
        public var items: [String]
        public var tabs: Int
        /// It shows the toast; else it is dropped.
        public var shows: Bool
    }

    /// Files each recorded item under its waiting gesture: whether one took each item, and the
    /// gestures that settled. Nil when the FFI does not answer.
    public func recordClosed(_ state: UndoState, items: [RecordedItem]) -> (state: UndoState, matched: [Bool], settled: [Settled])? {
        struct Request: Encodable { var state: UndoState, items: [RecordedItem] }
        struct Recorded: Decodable { var matched: [Bool], settled: [Settled] }
        struct Reply: Decodable { var state: UndoState, recorded: Recorded }
        guard let reply = call("window_close_undo_record", Request(state: state, items: items), as: Reply.self) else { return nil }
        return (reply.state, reply.recorded.matched, reply.recorded.settled)
    }

    /// How a settled close's toast shows.
    public nonisolated enum ToastShow: Equatable, Sendable {
        case new(tabs: Int), join(tabs: Int), drop
    }

    /// The toast for a close of `tabs`: `shown` the tab count of the close toast its window still
    /// shows, `allowed` the rate limit's answer.
    public func undoToast(tabs: Int, shown: Int?, allowed: Bool) -> ToastShow {
        struct Request: Encodable { var tabs: Int, shown: Int?, allowed: Bool }
        struct Reply: Decodable { var show: String, tabs: Int? }
        guard let reply = call("window_close_undo_toast", Request(tabs: tabs, shown: shown, allowed: allowed), as: Reply.self) else {
            return .new(tabs: tabs)
        }
        switch reply.show {
        case "join": return .join(tabs: reply.tabs ?? tabs)
        case "new": return .new(tabs: reply.tabs ?? tabs)
        default: return .drop
        }
    }
}
