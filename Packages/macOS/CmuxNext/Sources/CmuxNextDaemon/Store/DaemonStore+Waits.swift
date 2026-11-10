/// What a wait for one tab or one workspace reads (main-thread-scheduling.md section 3, O9): each wait re-runs its
/// lookup under observation until it matches or its time limit ends, so the lookup reads the one id it waits for (the
/// index) and the counters that tell it the tree changed, never a walk of every workspace, pane and tab.
extension DaemonStore {
    /// The tab on `surface`, with its pane and workspace, once the tree lists it. O(1) from the index; it reads
    /// `tabListRevision` (and `workspaces`), so a tracked wait hears the tab come, as `AppServices.locateTab` does.
    public func locatedTab(surface: SurfaceID) -> (tab: TabModel, pane: PaneModel, workspace: WorkspaceModel)? {
        _ = tabListRevision
        guard let tab = tab(surface: surface), let pane = pane(holding: tab), let workspace = location(of: pane)?.workspace else { return nil }
        return (tab, pane, workspace)
    }

    /// Whether the workspace with key `key` lists a conversation tab now. The workspace comes from the index; it reads
    /// `workspaces`, `workspaceSetRevision` (a workspace confirmed under its key) and `tabListRevision` (a tab comes),
    /// then that one workspace's tabs only.
    public func listsConversationTab(inWorkspace key: String) -> Bool {
        _ = (workspaces, workspaceSetRevision, tabListRevision)
        return workspace(key: WorkspaceKey(rawValue: key))?.screens
            .flatMap(\.panes).flatMap(\.tabs).contains(where: { $0.kind == .conversation }) ?? false
    }

    /// The workspace with public id `id`, once the tree lists it. O(1) from the index; it reads `workspaces` and
    /// `workspaceSetRevision` (a workspace confirmed under that id), never every workspace's id.
    public func listedWorkspace(resourceID id: ResourceID) -> WorkspaceModel? {
        _ = workspaceSetRevision
        return workspace(resourceID: id)
    }
}
