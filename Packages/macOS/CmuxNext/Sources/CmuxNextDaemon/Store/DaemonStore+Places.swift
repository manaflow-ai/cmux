extension DaemonStore {
    /// Where something an agent reported happened, by the names the person sees: the workspace,
    /// the tab and the tab's agent harness (`claude`, `codex`), from a tab id or `tab_…` resource
    /// id, a terminal `term_…` resource id, an agent chat's ACP session, or a workspace id or
    /// `ws_…` resource id. The first that resolves wins; nil when none does (another Mac's item).
    public func place(tab: String? = nil, terminal: String? = nil, agentSession: String? = nil,
                      workspace workspaceID: String? = nil) -> (workspace: String?, tab: String?, harness: String?)? {
        let found = tab.flatMap(self.tab(idOrResource:))
            ?? terminal.flatMap { self.tab(terminalResource: ResourceID(rawValue: $0)) }
            ?? agentSession.flatMap { self.tab(agentSession: $0) }
        var workspace = found.flatMap(pane(holding:)).flatMap { self.workspace(containing: $0.handle) }
        if workspace == nil, let workspaceID {
            workspace = self.workspace(id: workspaceID) ?? workspaces.first { $0.resourceID?.rawValue == workspaceID }
        }
        guard found != nil || workspace != nil else { return nil }
        return (workspace?.displayName, found?.displayTitle, found?.agentSession?.harness)
    }

    /// The chat tab that shows ACP session `session`, on `host` when one is given.
    public func tab(agentSession session: String, host: String? = nil) -> TabModel? {
        for workspace in workspaces {
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            where tab.agentSession?.session == session && (host == nil || tab.agentSession?.host == host) {
                return tab
            }
        }
        return nil
    }
}
