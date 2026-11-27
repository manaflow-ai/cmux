extension DaemonStore {
    /// The workspace with `WorkspaceModel.id` `id`, in O(1) from the index
    /// the store keeps (StoreIndex). It reads `workspaces` first, so a tracked
    /// caller still hears a workspace come or go.
    public func workspace(id: String) -> WorkspaceModel? {
        _ = workspaces
        return index.workspacesByID[id]
    }

    /// The workspace whose public id is `id`, in O(1) from the index. It reads `workspaces` first,
    /// so a tracked caller (a wait for a reopened workspace) still hears a workspace come or go.
    public func workspace(resourceID id: ResourceID) -> WorkspaceModel? {
        _ = workspaces
        return index.workspacesByResource[id]
    }

    /// The first daemon terminal of workspace `id` (never a provisional stand-in): the terminal the keys typed for a new
    /// workspace go into once the window shows it.
    public func firstTerminalTab(ofWorkspace id: String) -> TabModel? {
        workspace(id: id)?.screens.flatMap(\.panes).flatMap(\.tabs).first { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
    }

    /// Whether this store's tree holds `workspace` (by identity), in O(1) from the index. It reads no observable: a
    /// caller that holds the model already re-runs on that model's own changes, and must not re-run on every workspace
    /// made or closed elsewhere (TYPING UNDER LOAD F6: a sidebar row asked `workspace(id:)` and observed every workspace).
    public func holds(_ workspace: WorkspaceModel) -> Bool {
        index.workspacesByID[workspace.id] === workspace
    }
}
