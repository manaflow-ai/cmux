extension SidebarView {
    /// Opens the group editor (cx-rcby); a name edit emits `.renameGroup`.
    public func beginRename(group id: GroupID) {
        list.inlineRename.begin(.group(id))
    }

    /// The group whose editor is open, if any (cx-rcby).
    public var editingGroup: GroupID? { list.groupEditor.shownGroup }

    /// Starts inline rename of the active workspace.
    public func renameActiveWorkspace() {
        guard let active = model.activeWorkspaceID else { return }
        list.inlineRename.begin(.workspace(active))
    }
}
