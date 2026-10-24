// Which tabs a store's live tree lists, for the App's watchers that let go of a closed tab's view,
// surface or page (GoneTabWatch, AgentTabStore, InternalPageTabStore). They ask about the few tabs they
// track by O(1) lookups and wake on the store's tab-list revision, never by building the set of
// every tab of every workspace on each change: a script that moves panes or adds columns in 50
// workspaces then costs each watcher its own tabs, not the session (CLAUDE.md "Go past Chrome
// where cmux is scripted").
extension DaemonStore {
    /// The tab-list revision while the store is connected with a loaded tree, else nil: what a
    /// gone-tab watcher observes. It changes when a tab comes, goes or moves (``tabListRevision``).
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

    /// The pane with durable id `id` (``PaneModel/id``: its resource id, else `pane:<handle>`), by
    /// O(1) lookup; nil when the tree holds none. Reads `workspaces`, so a tracked caller hears a
    /// pane come or go with its workspace's tree.
    public func pane(id: String) -> PaneModel? {
        _ = tabListRevision
        if id.hasPrefix(Self.paneHandlePrefix), let raw = UInt64(id.dropFirst(Self.paneHandlePrefix.count)) {
            let byHandle: [PaneID: PaneModel] = index.panesByHandle
            return byHandle[PaneID(rawValue: raw)].flatMap { $0.id == id ? $0 : nil }
        }
        let byResource: [ResourceID: PaneModel] = index.panesByResource
        return byResource[ResourceID(rawValue: id)]
    }

    /// Whether the live tree lists the pane with durable id `id`; nil while the store has no live tree.
    public func liveTreeLists(pane id: String) -> Bool? {
        guard liveTabListRevision != nil else { return nil }
        return pane(id: id) != nil
    }

    /// The prefix of a pane id with no resource id (``PaneModel/identity(_:)``).
    private static let paneHandlePrefix = "pane:"
}
