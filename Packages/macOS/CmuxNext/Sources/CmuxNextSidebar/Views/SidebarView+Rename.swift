extension SidebarView {
    /// Starts inline rename of a group. Commit emits `.renameGroup`.
    public func beginRename(group id: GroupID) {
        list.inlineRename.begin(.group(id))
    }

    /// Starts inline rename of the active workspace.
    public func renameActiveWorkspace() {
        guard let active = model.activeWorkspaceID else { return }
        list.inlineRename.begin(.workspace(active))
    }
}
