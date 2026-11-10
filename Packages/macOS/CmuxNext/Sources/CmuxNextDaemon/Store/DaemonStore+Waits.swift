/// What a wait for one tab or one workspace reads (main-thread-scheduling.md section 3, O9): each wait re-runs its
/// lookup under observation until it matches or its time limit ends, so the lookup reads the one id it waits for (the
/// index) and the counters that tell it the tree changed, never a walk of every workspace, pane and tab.
///
/// Still session-wide: `tabListRevision`, which ``locatedTab(surface:)`` and ``listsConversationTab(inWorkspace:)``
/// read, moves on every tab add, move or close in any workspace (`publishTabListChange`). Each such wake costs O(1) or
/// O(one workspace's tabs), not a walk; ``listedWorkspace(resourceID:)`` reads its own id's cell only.
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

    /// The workspace with public id `id`, once the tree lists it. O(1) from the index; it reads only `id`'s own cell
    /// (``IDWaitCells``), which the index touches when a workspace is keyed under `id` or dropped from it: a workspace
    /// that comes under `id`, and a listed one whose `resourceID` an update sets to `id` in place (the set of workspaces
    /// does not change then). A change of any other workspace, or of the list, wakes no wait for `id`.
    public func listedWorkspace(resourceID id: ResourceID) -> WorkspaceModel? {
        index.workspaceResourceWaits.read(id)
        return index.workspacesByResource[id]
    }
}
