extension SidebarModel {
    /// Each workspace's place in this sidebar, top first (0), by workspace id: the palette's
    /// sidebar prior (`PaletteSidebarPrior`). One walk of the sections' nodes.
    public func workspaceRanks() -> [String: Int] {
        var ranks: [String: Int] = [:]
        for workspace in sections.flatMap(\.nodes).flatMap(\.workspaces) where ranks[workspace.id.rawValue] == nil {
            ranks[workspace.id.rawValue] = ranks.count
        }
        return ranks
    }
}
