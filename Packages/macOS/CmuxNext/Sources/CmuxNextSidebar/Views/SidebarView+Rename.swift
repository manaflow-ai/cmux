extension SidebarView {
    /// Opens the group editor (cx-rcby); a name edit emits `.renameGroup`.
    public func beginRename(group id: GroupID) {
        list.inlineRename.begin(.group(id))
    }
}
