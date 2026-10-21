public extension SidebarEdits {
    /// The section-row index `SidebarIntent.reorderGroup` takes to move
    /// `group` as `move` says (``SidebarGroupMove``).
    ///
    /// The index counts the section's rows, loose workspaces and groups
    /// alike, after the group is taken out (`reorderGroup`'s rule).
    /// - Parameters:
    ///   - group: The group to move.
    ///   - move: Where it goes.
    ///   - sections: The sidebar's sections.
    /// - Returns: The index, or nil when the group is not listed or already
    ///   is where `move` would send it.
    nonisolated static func groupIndex(_ group: GroupID, _ move: SidebarGroupMove, in sections: [SidebarSection]) -> Int? {
        guard let (section, node) = locateGroup(group, in: sections) else { return nil }
        let last = sections[section].nodes.count - 1
        let target = switch move {
        case .top: 0
        case .bottom: last
        case .up: node - 1
        case .down: node + 1
        }
        guard (0...last).contains(target), target != node else { return nil }
        return target
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
