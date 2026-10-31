import CoreGraphics

// An open group with no members (user 9757): one quiet row under its header, as tall and as far in as a
// one-line member row, so the group reads as open and empty instead of a header with the next group right
// under it. The row is a drop target: the resolver leaves it out (`RustRow.resolvable`), so a pointer over
// it falls on the open header's lower part, which drops into the group at its start.
nonisolated extension SidebarLayout {
    /// Whether an open `group` with no shown members lists its empty row: never while filtering (the group
    /// hides or shows the path to a match), never for a saved group (a click reopens it), and never for a
    /// group holding subgroups (they follow it).
    static func listsEmptyRow(_ group: SidebarGroup, filtering: Bool, hasSubgroups: Bool) -> Bool {
        !filtering && !group.isPinned && !hasSubgroups
    }

    /// Appends `group`'s empty row at `y` (member depth, the group's color for its line) and returns the y after it.
    static func appendEmptyRow(_ group: SidebarGroup, section: SectionID, parent: Int, metrics m: SidebarLayoutMetrics,
                               to rows: inout [SidebarRow], y: CGFloat) -> CGFloat {
        let h = m.height(for: WorkspaceRowContent())
        var row = SidebarRow(
            key: .emptyGroup(group.id), y: y, height: h, section: section,
            group: group.id, siblingIndex: 0, parentIndex: parent, isLastInGroup: true,
            isCollapsed: false, childCount: 0, groupColor: group.color
        )
        row.depth = group.depth + 1
        rows.append(row)
        return y + h + m.rowSpacing
    }
}
