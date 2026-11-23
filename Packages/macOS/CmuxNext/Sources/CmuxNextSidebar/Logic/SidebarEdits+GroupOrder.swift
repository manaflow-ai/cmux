public extension SidebarEdits {
    /// The section-row index `SidebarIntent.reorderGroup` takes to move
    /// `group` as `move` says (``SidebarGroupMove``).
    ///
    /// The index counts the section's rows, loose workspaces and groups
    /// alike, after the group is taken out (`reorderGroup`'s rule). A group
    /// steps over the top-level rows: a neighbour group moves with the
    /// subgroups listed after it, so one step passes it whole, and the index
    /// never names a subgroup's row (that gap is inside its parent).
    /// - Parameters:
    ///   - group: The group to move.
    ///   - move: Where it goes.
    ///   - sections: The sidebar's sections.
    /// - Returns: The index, or nil when the group is not listed, is a
    ///   subgroup (it moves with its parent), or already is where `move`
    ///   would send it.
    nonisolated static func groupIndex(_ group: GroupID, _ move: SidebarGroupMove, in sections: [SidebarSection]) -> Int? {
        var request = RustEditRequest("group_index", sections: RustSidebarEdits(sections).sections)
        let step = switch move {
        case .top: "top"
        case .bottom: "bottom"
        case .up: "up"
        case .down: "down"
        }
        (request.group, request.step) = (group.rawValue, step)
        return RustSidebarClient.call("sidebar_edits", request, as: Int?.self) ?? nil
    }

    /// The groups whose collapse Collapse Other Groups toggles, in sidebar
    /// order: every other expanded group, and `group` itself when it is
    /// collapsed (it opens, as Slack's "Collapse all other sections").
    /// - Parameters:
    ///   - group: The group that stays open.
    ///   - sections: The sidebar's sections.
    /// - Returns: The groups to toggle; empty when nothing changes.
    nonisolated static func groupsToggledByCollapsingOthers(keeping group: GroupID, in sections: [SidebarSection]) -> [GroupID] {
        var request = RustEditRequest("groups_toggled_by_collapsing_others", sections: RustSidebarEdits(sections).sections)
        request.keeping = group.rawValue
        return (RustSidebarClient.call("sidebar_edits", request, as: [String].self) ?? []).map(GroupID.init)
    }
}
