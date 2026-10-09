extension SidebarView {
    /// Starts inline rename of a group. Commit emits `.renameGroup`.
    public func beginRename(group id: GroupID) {
        list.inlineRename.begin(.group(id))
    }

    /// The group whose name is being edited, if any.
    public var editingGroup: GroupID? {
        if case let .group(id)? = list.inlineRename.session?.key { return id }
        return nil
    }

    /// Starts inline rename of the active workspace.
    public func renameActiveWorkspace() {
        guard let active = model.activeWorkspaceID else { return }
        list.inlineRename.begin(.workspace(active))
    }
}
