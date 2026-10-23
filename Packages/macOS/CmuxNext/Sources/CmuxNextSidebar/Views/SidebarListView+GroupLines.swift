import AppKit
import CmuxNextDesign

/// One open group's members' line (cx-qno.17), in the coordinates of the
/// row frames it was computed from.
struct SidebarGroupLine: Equatable {
    var group: GroupID
    var frame: CGRect
    var color: GroupTint
    /// The group's tree level: a nested group's rail is fainter, so stacked rails stay quiet.
    var level = 0

    /// How much of its color a rail at `level` draws: 1 at the top, then less per level.
    static func opacity(level: Int) -> CGFloat { max(0.35, 1 - 0.2 * CGFloat(level)) }
}

// The members' line (the Chrome tab group line): ONE view per open group
// under the rows (SidebarGroupLineViews), from under the header bar to the
// end of the last member row. Per-row pieces left gaps at the row spacing and
// under the header (cx-qno.17 proof), so the line is drawn per group.
extension SidebarListViewComponents {
    /// The list's lines. Rows a drag hides (`suppressed`) have none: a lifted
    /// group's line goes with its card (SidebarListLift). `current` places
    /// each row where its view is now, the animation's start, so a new line
    /// starts over its rows and moves with them (cx-ai79).
    func groupLines(_ layout: SidebarLayout, current: Bool = false) -> [SidebarGroupLine] {
        let lines = SidebarGroupLine.lines(layout.rows.filter { !suppressed.contains($0.key) }, colors: groups, nested: !legacyNestedRails) { row in
            current ? rowViews[row.key]?.frame ?? frame(for: row) : frame(for: row)
        }
        // `sidebar.showColors` off: every group draws as one with no color, its line unseen.
        guard !model.showsColors else { return lines }
        return lines.map { line in
            var line = line
            line.color = .none
            return line
        }
    }
}

extension SidebarGroupLine {
    /// Every open group in `rows` with shown members: its line from just
    /// under the header bar, rounded off there (cg-design-judge 2026-10-14: a
    /// line under the bar cut its rounded corner), to the last member row's
    /// bottom, rounded off just above it, just left of the members' rows
    /// (`SidebarStyle.groupLineX`), so no row fill covers it
    /// (cx-q5jw: straight and unbroken, Edge style). `frame` places a row.
    /// With `nested` off, the rails before the nested-groups prototype: one per group, ending at its own
    /// last member, at full strength (the "before" capture).
    /// A header's bar reaches left of its own members' x over the line (`SidebarStyle.groupRailReach`): the line
    /// starts at the header frame's left edge, the bar's.
    static func lines(_ rows: [SidebarRow], colors: [GroupID: SidebarGroup], nested: Bool = true,
                      frame: (SidebarRow) -> CGRect) -> [SidebarGroupLine] {
        var headers: [(GroupID, SidebarRow)] = []
        var last: [GroupID: SidebarRow] = [:]
        var drawn = Set<GroupID>()
        // A row ends its own group's rail and every drawn ancestor's (nested-groups prototype): a subgroup sits
        // inside its parent's rail, so nesting reads as nesting, never as a sibling drawn a little to the right.
        func extend(_ group: GroupID, to row: SidebarRow) {
            var current: GroupID? = group
            var seen = Set<GroupID>()
            while let id = current, drawn.contains(id), seen.insert(id).inserted {
                last[id] = row
                current = nested ? colors[id]?.parent : nil
            }
        }
        for row in rows {
            switch row.key {
            case let .group(id):
                headers.append((id, row))
                drawn.insert(id)
                if nested, let parent = colors[id]?.parent { extend(parent, to: row) }
            case .workspace, .tab, .item, .emptyGroup: if let group = row.group { extend(group, to: row) }
            default: break
            }
        }
        let width = SidebarStyle.groupBarWidth
        return headers.compactMap { id, header in
            guard !header.isCollapsed, let end = last[id], end.y > header.y else { return nil }
            let head = frame(header), tail = frame(end)
            // The header's bar fills its row: the line starts just under it.
            let top = head.maxY + Metrics.space1, bottom = tail.maxY - Metrics.space1
            guard bottom > top else { return nil }
            // At the header bar's left edge, which reaches left of the group's own members' x by the rail and its gap
            // (`SidebarListView.railReach(for:)`; not the subtree's last row, which may sit deeper).
            let x = head.minX
            return SidebarGroupLine(group: id, frame: CGRect(x: x, y: top, width: width, height: bottom - top),
                                    color: colors[id]?.tint ?? .palette(end.groupColor ?? .grey), level: nested ? header.depth : 0)
        }
    }
}
