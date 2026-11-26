/// The close handlers' decisions (cmux-window-rules `handlers_close`, ops `handlers_close_*`):
/// the app sends the facts it read and acts on the answer. Each names its answer for an FFI
/// that does not answer (an app built before the op): the safe one.
extension WindowRules {
    // MARK: TabCloseGuard

    /// One pane a closing selection leaves, as the hide before the daemon's read reads it.
    public nonisolated struct LeavingPart: Encodable, Equatable, Sendable {
        var sameDaemon: Bool
        var emptied: Bool
        var canShowPaneClose: Bool
        var closesBrowser: Bool
        var pageDecides: Bool

        public init(sameDaemon: Bool, emptied: Bool, canShowPaneClose: Bool, closesBrowser: Bool, pageDecides: Bool) {
            self.sameDaemon = sameDaemon
            self.emptied = emptied
            self.canShowPaneClose = canShowPaneClose
            self.closesBrowser = closesBrowser
            self.pageDecides = pageDecides
        }
    }

    /// Whether a person's close hides its tabs while the daemon is read. No hide when the FFI does not answer.
    public func closeHides(_ parts: [LeavingPart], knownToAsk: Bool) -> Bool {
        struct Request: Encodable { var parts: [LeavingPart], knownToAsk: Bool }
        struct Reply: Decodable { var hides: Bool }
        return call("handlers_close_hides", Request(parts: parts, knownToAsk: knownToAsk), as: Reply.self)?.hides ?? false
    }

    /// The input event AppKit is dispatching when Close Tab runs: `keyDown`, `keyUp`, `mouse` or `none`.
    public nonisolated struct ClosePress: Decodable, Equatable, Sendable {
        /// The press's time is the event's; false: the invocation's input time, else now.
        public var eventTime: Bool
        public var isKey: Bool
        public var isRepeat: Bool
    }

    /// How a Close Tab press of `event` reads. With no answer, the invocation's time, not a key.
    public func closePress(event: String, isRepeat: Bool) -> ClosePress {
        struct Request: Encodable { var event: String, isRepeat: Bool }
        return call("handlers_close_press", Request(event: event, isRepeat: isRepeat), as: ClosePress.self)
            ?? ClosePress(eventTime: false, isKey: false, isRepeat: false)
    }

    /// A tab close's question, its strings still to look up.
    public nonisolated struct TabClosePrompt: Decodable, Equatable, Sendable {
        public enum Title: Decodable, Equatable, Sendable {
            case one(String)
            case count(Int)

            private enum CodingKeys: String, CodingKey { case kind, title, count }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(String.self, forKey: .kind) {
                case "one": self = .one(try container.decode(String.self, forKey: .title))
                default: self = .count(try container.decode(Int.self, forKey: .count))
                }
            }

            /// The title's text from the app's strings.
            public func text(one: (String) -> String, count: (Int) -> String) -> String {
                switch self {
                case .one(let title): one(title)
                case .count(let n): count(n)
                }
            }
        }

        public enum Line: Decodable, Equatable, Sendable {
            /// The agent's name, nil when unnamed.
            case agentWorking(String?)
            case stillRunning(String)
            case noAnswer(String)

            private enum CodingKeys: String, CodingKey { case kind, agent, joined }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(String.self, forKey: .kind) {
                case "agentWorking": self = .agentWorking(try container.decodeIfPresent(String.self, forKey: .agent))
                case "stillRunning": self = .stillRunning(try container.decode(String.self, forKey: .joined))
                default: self = .noAnswer(try container.decode(String.self, forKey: .joined))
                }
            }
        }

        public var title: Title
        public var body: [Line]
        /// `agentSession` or `tab`: which warning setting "Don't ask again" turns off.
        public var suppresses: String

        /// The body's text from the app's strings, its lines joined by a space.
        public func bodyText(agentWorking: (String?) -> String, stillRunning: (String) -> String, noAnswer: (String) -> String) -> String {
            body.map { line in
                switch line {
                case .agentWorking(let agent): agentWorking(agent)
                case .stillRunning(let joined): stillRunning(joined)
                case .noAnswer(let joined): noAnswer(joined)
                }
            }.joined(separator: " ")
        }
    }

    /// The question `warning` asks for closing tabs titled `titles`; nil when the FFI does not answer.
    public func tabClosePrompt(_ warning: Warning, titles: [String]) -> TabClosePrompt? {
        struct Request: Encodable {
            struct Facts: Encodable { var kind: String, name: String?, programs: [String]?, unanswered: [String]? }
            var warning: Facts
            var titles: [String]
        }
        let facts: Request.Facts = switch warning {
        case .agent(let name): .init(kind: "agent", name: name, programs: nil, unanswered: nil)
        case .programs(let programs, let unanswered): .init(kind: "programs", name: nil, programs: programs, unanswered: unanswered)
        }
        return call("handlers_close_tab_prompt", Request(warning: facts, titles: titles), as: TabClosePrompt.self)
    }

    // MARK: TabRestart, HistoryHandlers

    /// What `tab.restart` does: `restart`, `refuseNotATerminal` or `refuseTabNotDead` (the answer when the FFI does not).
    public func restartStep(_ refusal: (refusal: String?, answered: Bool)) -> String { restartStep(refusal: refusal.refusal, answered: refusal.answered) }

    public func restartStep(refusal: String?, answered: Bool) -> String {
        struct Request: Encodable { var refusal: String?, answered: Bool }
        return call("handlers_close_restart_step", Request(refusal: refusal, answered: answered), as: String.self) ?? "refuseTabNotDead"
    }

    /// What `history.open` does with its lookup (`found`, `stillLoading`, `gone`): `open`, `stillLoading` or
    /// `entryGone` (the answer when the FFI does not).
    public func historyOpening(lookup: String, available: Bool) -> String {
        struct Request: Encodable { var lookup: String, available: Bool }
        return call("handlers_close_history_opening", Request(lookup: lookup, available: available), as: String.self) ?? "entryGone"
    }

    // MARK: CloseUndoToasts

    /// How many of the oldest recent daemon items to drop past the kept few (none when the FFI does not answer).
    public func recentOverflow(_ count: Int) -> Int {
        struct Request: Encodable { var count: Int }
        struct Reply: Decodable { var drop: Int }
        return call("handlers_close_recent_overflow", Request(count: count), as: Reply.self)?.drop ?? 0
    }

    /// A tab close toast's message.
    public nonisolated enum ToastMessage: Decodable, Equatable, Sendable {
        case tabsClosed(Int)
        case tabClosed(String)
        case untitled

        private enum CodingKeys: String, CodingKey { case kind, count, title }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "tabsClosed": self = .tabsClosed(try container.decode(Int.self, forKey: .count))
            case "tabClosed": self = .tabClosed(try container.decode(String.self, forKey: .title))
            default: self = .untitled
            }
        }

        /// The message's text from the app's strings.
        public func text(tabsClosed: (Int) -> String, tabClosed: (String) -> String, untitled: String) -> String {
            switch self {
            case .tabsClosed(let count): tabsClosed(count)
            case .tabClosed(let title): tabClosed(title)
            case .untitled: tabClosed(untitled)
            }
        }
    }

    /// The toast for closing `tabs` tabs (`title`: the one tab's); "Untitled" when the FFI does not answer.
    public func toastMessage(tabs: Int, title: String) -> ToastMessage {
        struct Request: Encodable { var tabs: Int, title: String }
        return call("handlers_close_toast_message", Request(tabs: tabs, title: title), as: ToastMessage.self) ?? .untitled
    }

    // MARK: Workspace closes

    /// The facts of a bulk workspace close's run.
    public nonisolated struct BulkRunFacts: Encodable, Equatable, Sendable {
        var byGroup: Bool
        var user: Bool
        var count: Int
        var oneWindow: Bool
        var survivor: Bool
        var refusesEmpty: Bool

        public init(byGroup: Bool, user: Bool, count: Int, oneWindow: Bool, survivor: Bool, refusesEmpty: Bool) {
            self.byGroup = byGroup
            self.user = user
            self.count = count
            self.oneWindow = oneWindow
            self.survivor = survivor
            self.refusesEmpty = refusesEmpty
        }
    }

    /// What a bulk workspace close does: `nothingToClose`, `selection`, `closeWithUndo` or `close` (no answer).
    public func bulkRun(_ facts: BulkRunFacts) -> String {
        call("handlers_close_bulk_run", facts, as: String.self) ?? "close"
    }

    private nonisolated struct Undo: Encodable { var user: Bool, names: Int, survivor: Bool }
    private nonisolated struct Offers: Decodable { var offers: Bool }

    /// Whether Close Workspaces in Group offers its undo (none when the FFI does not answer).
    public func groupCloseOffersUndo(user: Bool, names: Int, survivor: Bool) -> Bool {
        call("handlers_close_group_offers_undo", Undo(user: user, names: names, survivor: survivor), as: Offers.self)?.offers ?? false
    }

    /// Whether a selection close's settled batch offers its undo (none when the FFI does not answer).
    public func selectionOffersUndo(names: Int, survivor: Bool) -> Bool {
        call("handlers_close_selection_offers_undo", Undo(user: true, names: names, survivor: survivor), as: Offers.self)?.offers ?? false
    }

    // MARK: DestructiveConfirmation

    /// The fixed question of action `id` (`killMachine`, `deleteSnapshot`, `removeFile`, `deleteFirewallRule`,
    /// `secretRemove`, `worktreeRemove`) and whether Return confirms it; nil for none or no answer.
    public func fixedPrompt(_ id: String) -> (prompt: String, returnConfirms: Bool)? {
        struct Request: Encodable { var id: String }
        struct Reply: Decodable { var prompt: String?, returnConfirms: Bool? }
        guard let reply = call("handlers_close_fixed_prompt", Request(id: id), as: Reply.self), let prompt = reply.prompt else { return nil }
        return (prompt, reply.returnConfirms ?? true)
    }

    // MARK: DaemonClosedHistory

    private nonisolated struct ID: Encodable { var id: String }

    /// The id a history list gives daemon item `id`.
    public func historyID(_ id: String) -> String {
        struct Reply: Decodable { var historyId: String }
        return call("handlers_close_history_id", ID(id: id), as: Reply.self)?.historyId ?? "daemon:" + id
    }

    /// The daemon item id of history list id `id`, nil for the app's trackers (and when the FFI does not answer).
    public func daemonID(fromHistoryID id: String) -> String? {
        struct Reply: Decodable { var daemonId: String? }
        return call("handlers_close_daemon_id", ID(id: id), as: Reply.self)?.daemonId
    }

    /// The window id of window record `record` (`install/window`); the record itself when the FFI does not answer.
    public func recordWindow(_ record: String) -> String {
        struct Request: Encodable { var record: String }
        struct Reply: Decodable { var window: String }
        return call("handlers_close_record_window", Request(record: record), as: Reply.self)?.window ?? record
    }

    /// `seconds` since 1970 as the daemon's milliseconds (0 before it, and when the FFI does not answer).
    public func sinceMs(_ seconds: Double) -> UInt64 {
        struct Request: Encodable { var seconds: Double }
        struct Reply: Decodable { var sinceMs: UInt64 }
        return call("handlers_close_since_ms", Request(seconds: seconds), as: Reply.self)?.sinceMs ?? 0
    }

    /// Whether a clear from `sinceMs` (nil: all) takes an item closed at `closedAtMs`; true when the FFI does not answer.
    public func clears(closedAtMs: UInt64, sinceMs: UInt64?) -> Bool {
        struct Request: Encodable { var closedAtMs: UInt64, sinceMs: UInt64? }
        struct Reply: Decodable { var clears: Bool }
        return call("handlers_close_clears", Request(closedAtMs: closedAtMs, sinceMs: sinceMs), as: Reply.self)?.clears ?? true
    }

    private nonisolated struct KindFacts: Encodable { var kind: String, grouped: Bool, code: String?, tabInPane: Bool }

    /// What a failed `closed.reopen` of a `kind` item says: `noRecentlyClosedWorkspace` or `error` (no answer).
    public func reopenFailure(kind: String, grouped: Bool, code: String?) -> String {
        call("handlers_close_reopen_failure", KindFacts(kind: kind, grouped: grouped, code: code, tabInPane: false), as: String.self) ?? "error"
    }

    /// Whether a failed `closed.delete` with error `code` still reached its goal (not when the FFI does not answer).
    public func deleteDone(code: String?) -> Bool {
        struct Request: Encodable { var code: String? }
        struct Reply: Decodable { var done: Bool }
        return call("handlers_close_delete_done", Request(code: code), as: Reply.self)?.done ?? false
    }

    /// What a reopened `kind` item shows: `nothing`, `window`, `selectTab`, `workspace` or `show` (no answer).
    public func reopenShow(kind: String, grouped: Bool, tabInPane: Bool) -> String {
        call("handlers_close_reopen_show", KindFacts(kind: kind, grouped: grouped, code: nil, tabInPane: tabInPane), as: String.self) ?? "show"
    }
}
