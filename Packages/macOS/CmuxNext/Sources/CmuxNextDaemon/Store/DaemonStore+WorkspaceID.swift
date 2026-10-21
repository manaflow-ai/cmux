extension DaemonStore {
    /// The workspace with `WorkspaceModel.id` `id`, in O(1) from the index
    /// the store keeps (StoreIndex). It reads `workspaces` first, so a tracked
    /// caller still hears a workspace come or go.
    public func workspace(id: String) -> WorkspaceModel? {
        _ = workspaces
        return index.workspacesByID[id]
    }
}
