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
    /// Every open group in `rows` with shown members: its line from its header to the last member row's bottom,
    /// Chrome's shape (Leo 2026-10-19): 2 pt (`SidebarStyle.groupBarWidth`), flat ends, a cut
    /// (`SidebarStyle.groupLineCut`, never past the top of the row under the header) below the bar, or out of the bar's square corner when `joined` under the solid
    /// band (`joinsBar`); just left of the members' rows (`SidebarStyle.groupLineX`), so no row fill covers it
    /// (cx-q5jw: straight and unbroken, Edge style). `frame` places a row.
    /// With `nested` off, the rails before the nested-groups prototype: one per group, ending at its own
    /// last member, at full strength (the "before" capture).
    /// A header's bar reaches left of its own members' x over the line (`SidebarStyle.groupRailReach`): the line
    /// starts at the header frame's left edge, the bar's.
    static func lines(_ rows: [SidebarRow], colors: [GroupID: SidebarGroup], nested: Bool = true,
                      layout: SidebarGroupLineLayout = SidebarStyle.groupLineLayout, joinsBar: Bool = SidebarGroupLine.joinsBar,
                      frame: (SidebarRow) -> CGRect) -> [SidebarGroupLine] {
        var headers: [(GroupID, SidebarRow)] = []
        // Groups drawn as their one member's row (`SidebarRow.standsForGroup`): a line along that row, no header.
        var soles: [(GroupID, SidebarRow)] = []
        var last: [GroupID: SidebarRow] = [:]
        var first: [GroupID: SidebarRow] = [:] // each group's first own member, whose x the rail keeps
        var below: [GroupID: SidebarRow] = [:] // the row right under each header: the rail never starts inside it
        var pending = Set<GroupID>()
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
            for id in pending { below[id] = row }
            pending.removeAll()
            switch row.key {
            case let .group(id):
                headers.append((id, row))
                drawn.insert(id)
                pending.insert(id)
                if nested, let parent = colors[id]?.parent { extend(parent, to: row) }
            case .workspace, .item, .emptyGroup:
                if row.standsForGroup, let group = row.group {
                    soles.append((group, row))
                    drawn.insert(group)
                }
                if let group = row.group { extend(group, to: row); first[group] = first[group] ?? row }
            default: break
            }
        }
        let width = SidebarStyle.groupBarWidth
        // A sole member's line runs the row's height at the bar's x a header would have: no bar above it, so no cut.
        let soleLines = soles.map { id, row in
            let head = frame(row), tail = frame(last[id] ?? row), bar = SidebarStyle.groupBarX(membersMinX: head.minX)
            let x = layout == .inside ? max(bar, SidebarStyle.groupLineX(membersMinX: head.minX)) : bar
            return SidebarGroupLine(group: id, frame: CGRect(x: x, y: head.minY,
                                                             width: width, height: tail.maxY - head.minY),
                                    color: colors[id]?.tint ?? .palette(row.groupColor ?? .grey), level: nested ? max(0, row.depth - 1) : 0)
        }
        return soleLines + headers.compactMap { id, header in
            guard !header.isCollapsed, let end = last[id], end.y > header.y else { return nil }
            let head = frame(header), tail = frame(end)
            // The header's bar fills its row: the line starts a cut under it, or joined, right where it ends. The cut is
            // at most the gap down to the row under the header, so the line never starts part way down that row
            // (Lawrence 2026-10-30, "alignment here is bad": a 6 pt cut under a 2.5 pt gap).
            let cutTop = below[id].map { max(head.maxY, frame($0).minY) } ?? head.maxY + SidebarStyle.groupLineCut
            let top = layout == .joined && joinsBar ? head.maxY : min(head.maxY + SidebarStyle.groupLineCut, cutTop), bottom = tail.maxY
            guard bottom > top else { return nil }
            // At the header bar's left edge, which reaches left of the group's own members' x by the rail and its gap
            // (`SidebarListView.railReach(for:)`; not the subtree's last row, which may sit deeper). `inside`, the bar
            // reaches further and the line keeps the rail's x, its first member's less the reach.
            let insideRail = first[id].map(frame).map { $0.minX - SidebarStyle.groupRailReach }
                ?? head.minX + SidebarStyle.groupHeaderOverhang
            let x = layout == .inside ? max(head.minX, insideRail)
                : head.minX
            return SidebarGroupLine(group: id, frame: CGRect(x: x, y: top, width: width, height: bottom - top),
                                    color: colors[id]?.tint ?? .palette(end.groupColor ?? .grey), level: nested ? header.depth : 0)
        }
    }
}

extension SidebarGroupLine {
    /// Whether a `joined` line joins its header's bar: only the solid band has one (the quieter header looks,
    /// `SidebarGroupHeaderStyle`, keep the line's cut).
    static var joinsBar: Bool { SidebarGroupHeaderStyle.tunable.value == .band }

    /// A group header bar's rounded corners: all four, or, for an `open` group whose line joins it (`joined`, the
    /// solid band), every one but the bottom-left, where the line runs out (`flipped`: the layer's y runs down).
    static func barCorners(open: Bool, flipped: Bool) -> CACornerMask {
        let all: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        guard open, SidebarStyle.groupLineLayout == .joined, joinsBar else { return all }
        return all.subtracting(flipped ? .layerMinXMaxYCorner : .layerMinXMinYCorner)
    }
}
