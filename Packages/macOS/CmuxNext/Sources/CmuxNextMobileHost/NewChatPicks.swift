public import CmuxNextAgentPane

/// The agent and model this Mac's New Tab page picked last (`newTab.lastAgent` and
/// `newTab.lastPicks`, Mac-local), as the iPhone host hands them to acpmux
/// (`_acpmux/new_chat_picks_set`): a phone's New Agent Chat starts where this Mac's does.
public struct NewChatPicks: Sendable, Equatable {
    /// The agent last picked (no model).
    public var lastAgent: String?
    /// The harness and model picked last, anywhere and per folder.
    public var picks: AgentPaneLastPicks?

    public init(lastAgent: String? = nil, picks: AgentPaneLastPicks? = nil) {
        self.lastAgent = lastAgent
        self.picks = picks
    }

    var isEmpty: Bool { lastAgent == nil && picks?.global == nil && (picks?.folders.isEmpty ?? true) }

    /// `_acpmux/new_chat_picks_set` params: `{lastAgent?, global?, folders}` (the newest 50 folders).
    var params: [String: Any] {
        var out: [String: Any] = [:]
        if let lastAgent { out["lastAgent"] = lastAgent }
        if let global = picks?.global { out["global"] = ["harness": global.harness, "model": global.model] }
        out["folders"] = (picks?.folders ?? []).suffix(AgentPaneLastPicks.maxFolders).map {
            ["folder": $0.folder, "harness": $0.harness, "model": $0.model]
        }
        return out
    }
}
