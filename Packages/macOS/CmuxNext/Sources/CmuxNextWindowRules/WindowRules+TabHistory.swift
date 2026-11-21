/// Strict tab history (cmux-window-rules `tab_history`, op `window_history_tab`): Go Back One Tab and
/// Go to Recent Tab, in any workspace or only in the current one. Every settled tab is a visit, apart
/// from the location trail; the app keeps the value and sends it with each op.
public nonisolated struct TabHistory: Codable, Equatable, Sendable {
    public nonisolated struct Visit: Codable, Equatable, Sendable {
        public var tab: String
        public var workspace: String
        public var machine: String

        public init(tab: String, workspace: String, machine: String) {
            self.tab = tab
            self.workspace = workspace
            self.machine = machine
        }
    }

    public nonisolated enum Step: String, Codable, Sendable {
        case back, recent
    }

    public nonisolated enum Scope: String, Codable, Sendable {
        case any, workspace
    }

    public nonisolated struct Walk: Codable, Equatable, Sendable {
        public var at: Int
        public var scope: Scope
    }

    public var visits: [Visit] = []
    public var walk: Walk?

    public init() {}
}

extension WindowRules {
    /// What a tab history op answers: the history to keep and, for a step, the tab to show.
    public nonisolated struct TabHistoryReply: Decodable, Sendable {
        public var history: TabHistory
        public var changed: Bool
        public var target: TabHistory.Visit?
    }

    /// A tab settled.
    public func tabHistory(_ history: TabHistory, record visit: TabHistory.Visit) -> TabHistoryReply? {
        struct Request: Encodable { var op = "record", history: TabHistory, visit: TabHistory.Visit }
        return call("window_history_tab", Request(history: history, visit: visit), as: TabHistoryReply.self)
    }

    /// The tab `step` shows within `scope` from `current`; no target: nowhere to go.
    public func tabHistory(_ history: TabHistory, step: TabHistory.Step, scope: TabHistory.Scope,
                           current: TabHistory.Visit) -> TabHistoryReply? {
        struct Request: Encodable {
            var op = "step", history: TabHistory, step: TabHistory.Step, scope: TabHistory.Scope, current: TabHistory.Visit
        }
        return call("window_history_tab", Request(history: history, step: step, scope: scope, current: current),
                    as: TabHistoryReply.self)
    }

    /// A tab closed or could not be shown.
    public func tabHistory(_ history: TabHistory, forget tab: String) -> TabHistoryReply? {
        struct Request: Encodable { var op = "forget", history: TabHistory, tab: String }
        return call("window_history_tab", Request(history: history, tab: tab), as: TabHistoryReply.self)
    }
}
