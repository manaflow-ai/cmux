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
    public static let groupEdgeFraction: CGFloat = 0.25
    /// Lower fraction of the last row in a group that means "after the group".
    public static let groupExitFraction: CGFloat = 0.25
    /// Upper fraction of a section header that means "end of the previous section".
    public static let sectionTopFraction: CGFloat = 0.35

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
        sections: [SidebarSection]
    ) -> DropTarget? {
        guard !base.rows.isEmpty else { return nil }
        let (row, fraction) = hit(y: y, rows: base.rows)
        switch payload {
        case let .workspaces(ids):
            guard let target = workspaceTarget(row: row, fraction: fraction, base: base, sections: sections) else { return nil }
            return isValid(target, for: ids, sections: sections) ? target : nil
        case let .group(group):
            return groupTarget(group: group, row: row, fraction: fraction, y: y, base: base, sections: sections)
        }
    }

    /// The row under `y` and the pointer's fraction down that row. Spacing
    /// between rows belongs to the row above; outside the list clamps.
    static func hit(y: CGFloat, rows: [SidebarRow]) -> (SidebarRow, CGFloat) {
        if y < rows[0].y { return (rows[0], 0) }
        for (i, row) in rows.enumerated() {
            let next = i + 1 < rows.count ? rows[i + 1].y : .infinity
            if y < next {
                let fraction = row.height > 0 ? min(1, max(0, (y - row.y) / row.height)) : 0
                return (row, fraction)
            }
        }
        return (rows[rows.count - 1], 1)
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

/// Where a tab dragged in from a pane would land on the sidebar.
public nonisolated enum SidebarTabDrop: Hashable, Sendable {
    /// Move the tab into this workspace (row highlights; hovering spring-loads it).
    case intoWorkspace(WorkspaceID)
    /// Create a workspace holding the tab at this slot (a gap opens).
    /// `index` follows `DropPosition` rules; nothing is excluded.
    case newWorkspace(section: SectionID, group: GroupID?, index: Int)
    /// Create a workspace holding the tab at the end of this collapsed group.
    case intoGroup(GroupID)
}

extension DropResolver {
    /// Middle band of a workspace row that means "into this workspace".
    public static let tabIntoFraction: ClosedRange<CGFloat> = 0.25...0.75

    /// Resolves an external tab drag. `base` is the layout without a gap.
    /// `sourceMachine` restricts targets to that machine's workspaces (tabs
    /// never cross daemons); nil allows any machine.
    public static func resolveTabDrop(
        y: CGFloat,
        base: SidebarLayout,
        sections: [SidebarSection],
        sourceMachine: MachineID?
    ) -> SidebarTabDrop? {
        guard !base.rows.isEmpty else { return nil }
        let (row, fraction) = hit(y: y, rows: base.rows)
        func machineOK(_ machine: MachineID?) -> Bool {
            guard let sourceMachine else { return machine != nil }
            return machine == sourceMachine
        }
        if case let .workspace(id) = row.key, tabIntoFraction.contains(fraction) {
            guard let ws = SidebarEdits.workspace(id, in: sections), machineOK(ws.machineID) else { return nil }
            return .intoWorkspace(id)
        }
        switch workspaceTarget(row: row, fraction: fraction, base: base, sections: sections) {
        case let .position(position)?:
            guard case let .machine(machine) = position.section, machineOK(machine) else { return nil }
            return .newWorkspace(section: position.section, group: position.group, index: position.index)
        case let .intoGroup(group)?:
            guard let (s, _) = SidebarEdits.locateGroup(group, in: sections), machineOK(sections[s].machine?.id) else { return nil }
            return .intoGroup(group)
        case nil:
            return nil
        }
    }
}
