/// Who asked for a team invite, as the run's caller names itself: an agent
/// chat, a terminal, or nobody known (a script outside cmux).
public nonisolated struct TeamInviteRequester: Sendable, Equatable {
    /// What kind of tab asked.
    public enum Kind: Sendable, Equatable {
        /// An agent chat tab (`caller.agent_session`).
        case agentChat
        /// A terminal tab (`caller.terminal_id`).
        case terminal
        /// No tab named itself.
        case unknown
    }

    /// What kind of tab asked.
    public var kind: Kind
    /// The tab's title, empty for ``Kind/unknown``.
    public var name: String
    /// The tab to reveal on the panel's Show button, nil when none.
    public var tabID: String?

    /// Creates a requester.
    public init(kind: Kind, name: String, tabID: String? = nil) {
        self.kind = kind
        self.name = name
        self.tabID = tabID
    }

    /// The reference the panel shows ("Agent chat “a12”").
    var reference: String {
        switch kind {
        case .agentChat: TeamInviteStrings.agentChat(name)
        case .terminal: TeamInviteStrings.terminal(name)
        case .unknown: TeamInviteStrings.unknownRequester
        }
    }
}
