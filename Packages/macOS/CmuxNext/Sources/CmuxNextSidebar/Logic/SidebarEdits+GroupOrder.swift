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
        guard let (section, node) = locateGroup(group, in: sections) else { return nil }
        var staying = sections[section].nodes
        guard case let .group(moved) = staying.remove(at: node), moved.parent == nil else { return nil }
        let topLevel = staying.indices.filter { index in
            if case let .group(other) = staying[index] { other.parent == nil } else { true }
        }
        let current = topLevel.count(where: { $0 < node })
        let target = switch move {
        case .top: 0
        case .bottom: topLevel.count
        case .up: current - 1
        case .down: current + 1
        }
        guard (0...topLevel.count).contains(target), target != current else { return nil }
        return target < topLevel.count ? topLevel[target] : staying.count
    }

    /// The groups whose collapse Collapse Other Groups toggles, in sidebar
    /// order: every other expanded group, and `group` itself when it is
    /// collapsed (it opens, as Slack's "Collapse all other sections").
    /// - Parameters:
    ///   - group: The group that stays open.
    ///   - sections: The sidebar's sections.
    /// - Returns: The groups to toggle; empty when nothing changes.
    nonisolated static func groupsToggledByCollapsingOthers(keeping group: GroupID, in sections: [SidebarSection]) -> [GroupID] {
        groups(in: sections).filter { $0.id == group ? $0.isCollapsed : !$0.isCollapsed }.map(\.id)
    }
}
