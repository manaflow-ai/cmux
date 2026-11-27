extension DaemonStore {
    /// Where something an agent reported happened, by the names the person sees: the workspace,
    /// the tab and the tab's agent harness (`claude`, `codex`), from a tab id or `tab_…` resource
    /// id, a terminal `term_…` resource id, an agent chat's ACP session, or a workspace id or
    /// `ws_…` resource id. The first that resolves wins; nil when none does (another Mac's item).
    public func place(tab: String? = nil, terminal: String? = nil, agentSession: String? = nil,
                      workspace workspaceID: String? = nil) -> (workspace: String?, tab: String?, harness: String?)? {
        let found = self.tab(reported: tab, terminal: terminal, agentSession: agentSession)
        var workspace = found.flatMap(pane(holding:)).flatMap { self.workspace(containing: $0.handle) }
        if workspace == nil, let workspaceID {
            workspace = self.workspace(id: workspaceID) ?? workspaces.first { $0.resourceID?.rawValue == workspaceID }
        }
        guard found != nil || workspace != nil else { return nil }
        return (workspace?.displayName, found?.displayTitle, found?.agentSession?.harness)
    }

    /// The tab something an agent reported names: a tab id or `tab_…` resource id, else a terminal
    /// `term_…` resource id, else an agent chat's ACP session. The first that resolves wins.
    public func tab(reported tab: String?, terminal: String? = nil, agentSession: String? = nil) -> TabModel? {
        tab.flatMap(self.tab(idOrResource:))
            ?? terminal.flatMap { self.tab(terminalResource: ResourceID(rawValue: $0)) }
            ?? agentSession.flatMap { self.tab(agentSession: $0) }
    }

    /// The chat tab that shows ACP session `session`, on `host` when one is given.
    public func tab(agentSession session: String, host: String? = nil) -> TabModel? {
        // Lazily, stopping at the first: no array of every tab per call.
        workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            .first { $0.agentSession?.session == session && (host == nil || $0.agentSession?.host == host) }
    }

    /// Whether tab `id` is a chat of `host`'s acpmux bound to `session` (or to none yet): a tab of
    /// another machine or chat never stands for it (a Cloud chat's uploads, CloudUploads).
    public func holdsChat(tab id: String, host: String, session: String) -> Bool {
        guard let record = workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == id })?.agentSession,
              record.host == host else { return false }
        return (record.session ?? session) == session
    }
}
