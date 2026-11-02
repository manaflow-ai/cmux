extension DaemonStore {
    /// The workspace with `WorkspaceModel.id` `id`, in O(1) from the index
    /// the store keeps (StoreIndex). It reads `workspaces` first, so a tracked
    /// caller still hears a workspace come or go.
    public func workspace(id: String) -> WorkspaceModel? {
        _ = workspaces
        return index.workspacesByID[id]
    }

    /// Whether this store's tree holds `workspace` (by identity), in O(1) from the index. It reads no observable: a
    /// caller that holds the model already re-runs on that model's own changes, and must not re-run on every workspace
    /// made or closed elsewhere (TYPING UNDER LOAD F6: a sidebar row asked `workspace(id:)` and observed every workspace).
    public func holds(_ workspace: WorkspaceModel) -> Bool {
        index.workspacesByID[workspace.id] === workspace
    }
}
