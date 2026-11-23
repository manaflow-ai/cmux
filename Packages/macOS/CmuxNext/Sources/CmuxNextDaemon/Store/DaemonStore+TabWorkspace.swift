extension DaemonStore {
    /// Tab `id` when it is of `kind`, with the workspace that holds it now: three index lookups (the tab, its pane,
    /// the pane's workspace), no walk of the session. Exact in the turn of a store change, for a reader that asks
    /// about one tab where a per-workspace list is one main-actor turn behind (the browser host's `isDrivable`).
    /// It reads the tab list revision and the workspace list: not for a long-lived observation.
    public func tab(id: String, of kind: TabKind) -> (tab: TabModel, workspace: WorkspaceModel)? {
        guard let tab = tab(id: id), tab.kind == kind, let pane = pane(holding: tab),
              let workspace = workspace(containing: pane.handle) else { return nil }
        return (tab, workspace)
    }
}
