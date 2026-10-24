// Which tabs a store's live tree lists, for the App's watchers that let go of a closed tab's view,
// surface or page (GoneTabWatch, AgentTabStore, InternalPageTabStore). They ask about the few tabs they
// track by O(1) lookups and wake on the store's tab-list revision, never by building the set of
// every tab of every workspace on each change: a script that moves panes or adds columns in 50
// workspaces then costs each watcher its own tabs, not the session (CLAUDE.md "Go past Chrome
// where cmux is scripted").
extension DaemonStore {
    /// The tab-list revision while the store is connected with a loaded tree, else nil: what a
    /// gone-tab watcher observes. It changes when a tab comes, goes or moves, or a pane comes or goes (``tabListRevision``).
    public var liveTabListRevision: UInt64? {
        guard case .connected = connectionState, isLoaded else { return nil }
        return tabListRevision
    }

    /// Whether the live tree lists the tab with durable id `id`; nil while the store has no live
    /// tree (disconnected or not loaded), when no tab may be called gone.
    public func liveTreeLists(tab id: String) -> Bool? {
        guard liveTabListRevision != nil else { return nil }
        return tab(id: id) != nil
    }

    /// Whether the live tree lists the pane with durable id `id` (``PaneModel/id``); nil while the
    /// store has no live tree (disconnected or not loaded), when no pane may be called gone.
    public func liveTreeLists(pane id: String) -> Bool? {
        guard liveTabListRevision != nil else { return nil }
        return index.listsPane(id: id)
    }
}
