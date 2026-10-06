
extension SidebarLayoutOptions {
    /// The list's options: the model's, plus a drag's exclusions and the
    /// drop gap when `includeGap` (`SidebarListView.options`).
    @MainActor static func list(_ list: SidebarListView, includeGap: Bool) -> SidebarLayoutOptions {
        var o = list.model.listOptions()
        o.showsSoleMachineHeader = true
        if includeGap, case let .newWorkspace(section, group, index)? = list.external?.proposal {
            o.gap = DropPosition(section: section, group: group, index: index)
            o.gapHeight = list.metrics.rowHeight
        }
        guard let drag = list.drag else { return o }
        switch drag.payload {
        case let .workspaces(ids):
            o.excludedWorkspaces = Set(ids)
            o.showEmptyPinned = true
        case let .group(group):
            o.excludedGroup = group
        }
        if includeGap, case let .position(position) = drag.target {
            o.gap = position
            o.gapHeight = drag.gapHeight
        }
        return o
    }
}
