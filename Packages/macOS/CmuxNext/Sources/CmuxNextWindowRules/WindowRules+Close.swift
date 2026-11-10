public import CmuxNextDaemon

/// What a close asks first and whether it earns an undo toast (cmux-window-rules `close`).
extension WindowRules {
    /// The facts of one closing tab.
    public nonisolated struct ClosingTab: Encodable, Equatable, Sendable {
        public var kind: String
        public var dead = false
        /// An internal page (Settings, History, What's New, an app's page).
        public var page = false
        /// A new chat still on its New Tab page.
        public var newTabPage = false
        public var url: String?
        /// A new chat's typed text from before it has a session.
        public var unsentDraft = false
        /// The tab's agent is working or waiting on a permission answer.
        public var agentAtWork = false
        public var agent: String?
        /// The status map says the tab works or waits on the person.
        public var statusWorking = false

        @MainActor public init(_ tab: TabModel, page: Bool = false, newTabPage: Bool = false, unsentDraft: Bool = false,
                        agentAtWork: Bool, statusWorking: Bool = false) {
            kind = switch tab.kind {
            case .pty: "pty"
            case .browser: "browser"
            default: "other"
            }
            dead = tab.dead
            url = tab.url
            agent = tab.agent?.agent
            self.page = page
            self.newTabPage = newTabPage
            self.unsentDraft = unsentDraft
            self.agentAtWork = agentAtWork
            self.statusWorking = statusWorking
        }
    }

    /// Whether a close earns the undo toast.
    public nonisolated enum Toast: Decodable, Equatable, Sendable {
        case show
        case skip

        private enum CodingKeys: String, CodingKey { case decision }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .decision) {
            case "show": self = .show
            case "skip": self = .skip
            case let other: throw DecodingError.dataCorruptedError(forKey: .decision, in: container, debugDescription: "toast \(other)")
            }
        }
    }

    /// The close warning settings (`app.warnBeforeClosingTab`, `app.warnBeforeClosingAgentSession`).
    public nonisolated struct Warnings: Encodable, Equatable, Sendable {
        public var warnTab: Bool
        public var warnAgent: Bool

        public init(warnTab: Bool, warnAgent: Bool) {
            self.warnTab = warnTab
            self.warnAgent = warnAgent
        }
    }

    /// What a close reads before it knows its question.
    public nonisolated struct Reads: Decodable, Equatable, Sendable {
        /// The closing terminals' working agents as the question names them (nil: "The agent").
        public var agents: [String?]
        /// The closing live terminals with no working agent (indices into the closing tabs): asked what each runs.
        public var others: [Int]

        public init(agents: [String?], others: [Int]) {
            self.agents = agents
            self.others = others
        }
    }

    /// What the daemon said one asked terminal runs.
    public nonisolated struct TerminalAnswer: Encodable, Equatable, Sendable {
        /// The tab's title, named when the terminal gave no answer.
        public var title: String
        /// False: no answer in time, which never confirms that no program runs.
        public var answered: Bool
        /// The foreground program; nil for the shell only.
        public var program: String?

        public init(title: String, answered: Bool, program: String?) {
            self.title = title
            self.answered = answered
            self.program = program
        }
    }

    /// The one question a close of live terminals asks.
    public nonisolated enum Warning: Decodable, Equatable, Sendable {
        /// The agent working in a closing terminal; nil for an unnamed one.
        case agent(String?)
        /// Foreground programs, unique and sorted, and the titles of the terminals that gave no answer.
        case programs([String], unanswered: [String])

        private enum CodingKeys: String, CodingKey { case kind, name, programs, unanswered }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "agent": self = .agent(try container.decodeIfPresent(String.self, forKey: .name))
            case "programs": self = .programs(try container.decode([String].self, forKey: .programs),
                                              unanswered: try container.decode([String].self, forKey: .unanswered))
            case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "warning \(other)")
            }
        }
    }

    /// Whether closing `tabs` together earns the undo toast; nil when the FFI does not answer.
    public func closeToast(_ tabs: [ClosingTab]) -> Toast? {
        struct Request: Encodable { var tabs: [ClosingTab] }
        return call("window_close_toast", Request(tabs: tabs), as: Toast.self)
    }

    /// What closing `tabs` reads first, or nil when it never asks (no live terminal, both warnings off).
    /// `answered` is false when the FFI does not answer.
    public func closeReads(_ tabs: [ClosingTab], _ warnings: Warnings) -> (reads: Reads?, answered: Bool) {
        struct Request: Encodable { var tabs: [ClosingTab], warnTab: Bool, warnAgent: Bool }
        struct Reply: Decodable { var reads: Reads? }
        guard let reply = call("window_close_reads", Request(tabs: tabs, warnTab: warnings.warnTab, warnAgent: warnings.warnAgent), as: Reply.self) else {
            return (nil, false)
        }
        return (reply.reads, true)
    }

    /// The close's question from `reads`' agents and the terminals' answers, or nil to close at once.
    /// `unansweredAsks`: a terminal that gave no answer asks by its title (a person's close).
    public func closeWarning(agents: [String?], answers: [TerminalAnswer], unansweredAsks: Bool, _ warnings: Warnings) -> (warning: Warning?, answered: Bool) {
        struct Request: Encodable { var agents: [String?], answers: [TerminalAnswer], unansweredAsks: Bool, warnTab: Bool, warnAgent: Bool }
        struct Reply: Decodable { var warning: Warning? }
        let request = Request(agents: agents, answers: answers, unansweredAsks: unansweredAsks, warnTab: warnings.warnTab, warnAgent: warnings.warnAgent)
        guard let reply = call("window_close_warning", request, as: Reply.self) else { return (nil, false) }
        return (reply.warning, true)
    }

    /// `closeReads`, failing closed: when the FFI does not answer, every live terminal is read, so a close
    /// with a warning setting on never goes through silently.
    public func closeReadsFailingClosed(_ tabs: [ClosingTab], _ warnings: Warnings) -> Reads? {
        let asked = closeReads(tabs, warnings)
        if asked.answered { return asked.reads }
        guard warnings.warnTab || warnings.warnAgent else { return nil }
        let live = tabs.enumerated().filter { $0.element.kind == "pty" && !$0.element.dead }
        guard !live.isEmpty else { return nil }
        // As the rule reads them: a working agent is its own question; only the program warning reads the rest.
        let agents = live.filter(\.element.agentAtWork).map(\.element.agent)
        let others = warnings.warnTab ? live.filter { !$0.element.agentAtWork }.map(\.offset) : []
        return Reads(agents: agents, others: others)
    }

    /// `closeWarning`, failing closed: when the FFI does not answer, a working agent asks (with
    /// `warnAgent`), else the close asks by `titles` (the terminals it read, with `warnTab`) instead of
    /// closing at once.
    public func closeWarningFailingClosed(agents: [String?], answers: [TerminalAnswer], unansweredAsks: Bool,
                                          _ warnings: Warnings, titles: [String]) -> Warning? {
        let decided = closeWarning(agents: agents, answers: answers, unansweredAsks: unansweredAsks, warnings)
        if decided.answered { return decided.warning }
        // Each warning still obeys its own setting.
        if warnings.warnAgent, let agent = agents.first { return .agent(agent) }
        return warnings.warnTab && !titles.isEmpty ? .programs([], unanswered: titles) : nil
    }
}
