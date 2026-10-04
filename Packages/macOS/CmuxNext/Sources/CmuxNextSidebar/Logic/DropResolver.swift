public import CoreGraphics
import Foundation

/// What is being dragged.
public nonisolated enum DragPayload: Hashable, Sendable {
    case workspaces([WorkspaceID])
    case group(GroupID)
}

/// Maps a pointer position to a drop target.
///
/// Resolution runs against the *base* layout: the tree with dragged rows
/// removed and no gap. The displayed layout has a gap, which shifts rows below
/// it; `baseY(forDisplayY:)` undoes that shift so an open gap never feeds back
/// into the target that opened it (no oscillation at row edges).
public nonisolated enum DropResolver {
    /// Fraction of a collapsed group header, from each edge, that means
    /// "before/after the group" rather than "into the group".
    public static var groupEdgeFraction: CGFloat { SidebarTunables.groupEdgeFraction.value }
    /// Lower fraction of the last row in a group that means "after the group".
    public static var groupExitFraction: CGFloat { SidebarTunables.groupExitFraction.value }
    /// Upper fraction of a section header that means "end of the previous section".
    public static var sectionTopFraction: CGFloat { SidebarTunables.sectionTopFraction.value }

    /// Converts a pointer y in the displayed (gapped) layout to base
    /// coordinates. Returns nil while the pointer is inside the gap, meaning
    /// "keep the current target".
    public static func baseY(forDisplayY y: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> CGFloat? {
        guard let gapY else { return y }
        if y < gapY { return y }
        if y >= gapY + gapHeight { return y - gapHeight }
        return nil
    }

    public static func resolve(
        y: CGFloat,
        payload: DragPayload,
        base: SidebarLayout,
        sections: [SidebarSection],
        ungroupedFirst: Bool = false
    ) -> DropTarget? {
        guard !base.rows.isEmpty else { return nil }
        let (row, fraction) = hit(y: y, layout: base)
        switch payload {
        case let .workspaces(ids):
            guard var target = workspaceTarget(row: row, fraction: fraction, base: base, sections: sections) else { return nil }
            if ungroupedFirst { target = leadingUngrouped(target, moving: Set(ids), sections: sections) }
            return isValid(target, for: ids, sections: sections) ? target : nil
        case let .group(group):
            return groupTarget(group: group, row: row, fraction: fraction, y: y, base: base, sections: sections)
        }
    }

    /// The row under `y` and the pointer's fraction down that row. Spacing
    /// between rows belongs to the row above; outside the list clamps.
    static func hit(y: CGFloat, layout: SidebarLayout) -> (SidebarRow, CGFloat) {
        let rows = layout.rows
        guard let i = layout.lastIndex(startingAtOrBefore: y) else { return (rows[0], 0) }
        let row = rows[i]
        let fraction = row.height > 0 ? min(1, max(0, (y - row.y) / row.height)) : 0
        return (row, fraction)
    }

    static func workspaceTarget(row: SidebarRow, fraction f: CGFloat, base: SidebarLayout, sections: [SidebarSection]) -> DropTarget? {
        switch row.key {
        case .workspace:
            if let group = row.group {
                if row.isLastInGroup, f > 1 - groupExitFraction, let parent = row.parentIndex {
                    return .position(DropPosition(section: row.section, index: parent + 1))
                }
                return .position(DropPosition(section: row.section, group: group, index: f < 0.5 ? row.siblingIndex : row.siblingIndex + 1))
            }
            return .position(DropPosition(section: row.section, index: f < 0.5 ? row.siblingIndex : row.siblingIndex + 1))

        case .tab:
            guard let workspace = row.workspace,
                  let parent = base.row(for: .workspace(workspace)) else { return nil }
            if let group = parent.group {
                return .position(DropPosition(section: parent.section, group: group, index: parent.siblingIndex + 1))
            }
            return .position(DropPosition(section: parent.section, index: parent.siblingIndex + 1))

        case let .group(group):
            if row.isCollapsed {
                if f < groupEdgeFraction { return .position(DropPosition(section: row.section, index: row.siblingIndex)) }
                if f > 1 - groupEdgeFraction { return .position(DropPosition(section: row.section, index: row.siblingIndex + 1)) }
                return .intoGroup(group)
            }
            if f < 0.4 { return .position(DropPosition(section: row.section, index: row.siblingIndex)) }
            return .position(DropPosition(section: row.section, group: group, index: 0))

        case .section:
            if f < sectionTopFraction, let previous = previousExpandedSection(before: row, in: base) {
                return .position(DropPosition(section: previous.section, index: previous.childCount))
            }
            return .position(DropPosition(section: row.section, index: row.isCollapsed ? row.childCount : 0))

        case .emptySection:
            return .position(DropPosition(section: row.section, index: 0))
        }
    }

    static func groupTarget(
        group: GroupID,
        row: SidebarRow,
        fraction f: CGFloat,
        y: CGFloat,
        base: SidebarLayout,
        sections: [SidebarSection]
    ) -> DropTarget? {
        guard let (s, _) = SidebarEdits.locateGroup(group, in: sections) else { return nil }
        let home = sections[s].id
        let index: Int
        switch row.key {
        case .workspace where row.group != nil, .group:
            // Treat an expanded group as one block: its upper half means
            // before it, its lower half after it.
            let blockGroup = row.group!
            guard row.section == home else { return nil }
            let blockRows = base.rows.filter { $0.group == blockGroup }
            let top = blockRows.map(\.y).min() ?? row.y
            let bottom = blockRows.map(\.maxY).max() ?? row.maxY
            let groupIndex = row.parentIndex ?? row.siblingIndex
            index = y < (top + bottom) / 2 ? groupIndex : groupIndex + 1
        case .workspace:
            guard row.section == home else { return nil }
            index = f < 0.5 ? row.siblingIndex : row.siblingIndex + 1
        case .tab:
            guard row.section == home, let parent = row.workspace,
                  let parentRow = base.row(for: .workspace(parent)) else { return nil }
            index = parentRow.siblingIndex + 1
        case .section:
            if row.section == home {
                index = row.isCollapsed ? row.childCount : 0
            } else if f < sectionTopFraction, let previous = previousExpandedSection(before: row, in: base), previous.section == home {
                index = previous.childCount
            } else {
                return nil
            }
        case .emptySection:
            guard row.section == home else { return nil }
            index = 0
        }
        return .position(DropPosition(section: home, index: index))
    }

    /// With `ungroupedFirst`, a machine section lists loose workspaces
    /// before its groups (the daemon has no slot for one after a group): a
    /// top-level slot past the first group moves to just before it.
    static func leadingUngrouped(_ target: DropTarget, moving: Set<WorkspaceID>, sections: [SidebarSection]) -> DropTarget {
        guard case let .position(position) = target, position.group == nil,
              let section = sections.first(where: { $0.id == position.section }), section.machine != nil else { return target }
        let nodes = section.nodes.filter { node in
            if case let .workspace(ws) = node { return !moving.contains(ws.id) }
            return true
        }
        guard let firstGroup = nodes.firstIndex(where: { if case .group = $0 { true } else { false } }),
              position.index > firstGroup else { return target }
        return .position(DropPosition(section: position.section, index: firstGroup))
    }

    static func previousExpandedSection(before row: SidebarRow, in base: SidebarLayout) -> SidebarRow? {
        guard let i = base.rows.firstIndex(of: row) else { return nil }
        let previous = base.rows[..<i].last { if case .section = $0.key { return true } else { return false } }
        guard let previous, !previous.isCollapsed else { return nil }
        return previous
    }

    /// Workspaces may drop only into their own machine's section or the
    /// pinned area, and never into groups inside the pinned area.
    public static func isValid(_ target: DropTarget, for ids: [WorkspaceID], sections: [SidebarSection]) -> Bool {
        let section: SidebarSection?
        switch target {
        case let .position(position):
            section = sections.first { $0.id == position.section }
            if position.group != nil, section?.machine == nil { return false }
        case let .intoGroup(group):
            section = SidebarEdits.locateGroup(group, in: sections).map { sections[$0.section] }
        }
        guard let section else { return false }
        return ids.allSatisfy { id in
            guard let ws = SidebarEdits.workspace(id, in: sections) else { return false }
            return SidebarEdits.canPlace(ws, in: section)
        }
    }
}
