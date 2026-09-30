public import CoreGraphics
import Foundation

/// Where a double-click on empty sidebar space makes a new workspace: the
/// end of a machine section, or the end of the expanded group whose empty
/// part is under the pointer.
public nonisolated struct SidebarEmptyAreaTarget: Hashable, Sendable {
    public var section: SectionID
    public var group: GroupID?

    public init(section: SectionID, group: GroupID? = nil) {
        self.section = section
        self.group = group
    }
}

extension SidebarLayout {
    /// The new-workspace target for a double-click at `y`, or nil on a row.
    /// The row above decides: inside an expanded group (between its rows,
    /// or within its bottom padding) the group; anywhere else the end of the
    /// section of that row. Above every row, the first machine section.
    /// The pinned section takes no new workspace.
    public func emptyAreaTarget(at y: CGFloat, metrics: SidebarLayoutMetrics) -> SidebarEmptyAreaTarget? {
        guard row(at: y) == nil else { return nil }
        guard let index = lastIndex(startingAtOrBefore: y) else {
            return rows.first { $0.section != .pinned }.map { SidebarEmptyAreaTarget(section: $0.section) }
        }
        let above = rows[index]
        guard above.section != .pinned else { return nil }
        if let group = groupOpening(below: above) {
            let endsGroup = above.isLastInGroup || above.key == .group(group) && above.childCount == 0
            let extent = above.maxY + metrics.rowSpacing + (endsGroup ? metrics.groupBottomPadding : 0)
            if y < extent { return SidebarEmptyAreaTarget(section: above.section, group: group) }
        }
        return SidebarEmptyAreaTarget(section: above.section)
    }

    /// The expanded group whose space continues below `row`: a member's
    /// group, or an expanded header's own group.
    private func groupOpening(below row: SidebarRow) -> GroupID? {
        switch row.key {
        case .workspace: row.group
        case .group(let group): row.isCollapsed ? nil : group
        case .section, .emptySection: nil
        }
    }
}
