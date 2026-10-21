/// Where an acpmux session's chat opens as a tab (``AgentSessionTabOpener``): pure, so the choice
/// is tested without the app. A tab already showing the session wins, so a chat never shows in
/// two tabs that both stream it; then beside the tab of the chat it belongs with; then the pane
/// the caller named or the focused one.
nonisolated enum AgentSessionTabPlan<Pane: Equatable>: Equatable {
    /// A tab shows the session already: it is shown (focused only when asked), no tab is made.
    case existing(tab: String)
    /// Beside tab `anchor`: in its chat's side pane when one is open, else a split right of it.
    case beside(anchor: String)
    /// A new tab in this pane.
    case pane(Pane)
    /// Nowhere to open it.
    case refused

    static func choose(existing: String?, anchor: String?, pane: Pane?) -> Self {
        if let existing { return .existing(tab: existing) }
        if let anchor { return .beside(anchor: anchor) }
        if let pane { return .pane(pane) }
        return .refused
    }
}

/// What `agent.openSessionWorkspace` (CLI `agent open`, MCP `app_agent_open`) does for a session:
/// shows the tab that shows it already, else makes a workspace whose only tab is its chat. Every
/// call used to make a new workspace, so one chat streamed in two workspaces at once.
nonisolated enum AgentSessionWorkspacePlan: Equatable {
    case reveal(tab: String)
    case create

    static func choose(existing: String?) -> Self {
        if let existing { return .reveal(tab: existing) }
        return .create
    }
}
