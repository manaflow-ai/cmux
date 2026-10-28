import CmuxNextDaemon

/// Which tabs show the New Tab page, for the names and badges the strip, the sidebar and Home
/// give them: the pages this run opened (``AgentTabStore/newTabPages``), and the blank chat tabs
/// the store restored after a relaunch, which ``AgentTabStore/view(for:)`` opens as the page when
/// they first show. Until then they are named and badged as the page they will be, not as a chat
/// (cx-eqkt0). Read without making the page: the same rule as `view(for:)`.
@MainActor
enum RestoredNewTabPages {
    /// Whether `tab` shows the New Tab page. `workspace`: the workspace that holds `tab`, when the
    /// caller knows it (a pane's own); else it is looked up, only while a first chat is in flight.
    ///
    /// A pane snapshot runs this for each of its tabs, so it reads only the tab's own record and
    /// per-key state: never the tab list or the workspace list of a store. A lookup by id there
    /// (`AppServices.locateTab`) observes every tab add and close, and re-ran every pane holding a
    /// restored page on each split or close in any pane (cx-8w027.20, I2).
    static func shows(_ tab: TabModel, in tabs: AgentTabStore, workspace: WorkspaceHandle? = nil) -> Bool {
        let key = tabs.resolve(tab.id)
        // Observed per key: the strip and Home follow the pages this run opens and closes.
        if tabs.pageTabs.contains(key) || tabs.newTabPages[key] != nil { return true }
        // Cheap lookups first: a restored chat leaves here, before the host checks.
        guard let record = tab.agentSession, tabs.views[key] == nil, tabs.tabStores[key] == nil,
              (tabs.sessions[key] ?? record.session) == nil, tabs.seeds[key] == nil, !tabs.linkedSessions.contains(key),
              tabs.unsentDrafts.seed(for: key, session: nil) == nil,
              AgentPaneHostKind(record, localHost: tabs.localHost, chiefHost: tabs.chiefHost,
                                listedHere: tabs.daemonListing(tab)?.isLocal != false) != .remote else { return false }
        // The daemon whose tree lists this record, found by identity (no tab-list read).
        let daemon = tabs.daemonListing(tab)
        guard daemon?.isLocal != false else { return false }
        // A first chat in flight in its workspace (New Agent Chat) is that chat, never the page.
        guard !tabs.firstChats.isEmpty else { return true }
        let store = daemon?.store
        guard let handle = workspace ?? store?.pane(containing: tab.surface).flatMap({ store?.workspace(containing: $0.handle) })?.handle
        else { return true }
        return tabs.firstChats[handle] == nil
    }

    /// The tabs of `store` that show the New Tab page, with the pages this run opened.
    static func ids(in store: DaemonStore?, tabs: AgentTabStore) -> Set<String> {
        var ids = tabs.pageTabs.ids
        guard let store else { return ids }
        for tab in store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        where tab.agentSession != nil && !ids.contains(tab.id) && shows(tab, in: tabs) {
            ids.insert(tab.id)
        }
        return ids
    }
}
