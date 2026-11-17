import AppKit
import CmuxNextDesign

/// One open group's members' line (cx-qno.17), in the coordinates of the
/// row frames it was computed from.
struct SidebarGroupLine: Equatable {
    var group: GroupID
    var frame: CGRect
    var color: GroupTint
    /// The header bar's `sidebar.groupHeader.background` look: under glass the line takes the bar's translucent paint.
    var background: SidebarGroupBackgroundStyle = .auto
    /// The group's tree level: a nested group's rail is fainter, so stacked rails stay quiet.
    var level = 0
    /// A group with no color: `frame` is its block, the header and its members (`SidebarNoColorGroupLook`), not a rail.
    var isBlock = false

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
    ///
    /// Only the lines near the visible rows (`lineWindow`): a pass costs the rows on screen and the groups they sit in,
    /// never every row the list holds. A scroll past `lineCover` shows the lines it reaches (`showLinesInView`).
    func groupLines(_ layout: SidebarLayout, current: Bool = false) -> [SidebarGroupLine] {
        let window = lineWindow()
        lineCover = window
        let (rows, edge) = lineRows(layout, around: window)
        return styled(SidebarGroupLine.lines(rows.filter { !suppressed.contains($0.key) }, colors: lineColors, nested: !legacyNestedRails) { row in
            current ? rowViews[row.key]?.frame ?? frame(for: row) : frame(for: row)
        }.filter { $0.group != edge })
    }

    /// `lines` in the sidebar's settings: the header's `sidebar.groupHeader.background` look (Sections draws none), and
    /// with `sidebar.showColors` off every group as one with no color, its line unseen. Every path that makes lines (a
    /// rebuild, a fold, a lift) passes them through here, so none draws a look the headers do not.
    func styled(_ lines: [SidebarGroupLine]) -> [SidebarGroupLine] {
        let background = model.groupHeaderDetails.background, showsColors = model.showsColors
        return lines.map { line in
            var line = line
            line.background = background
            if !showsColors { line.color = .none }
            return line
        }
    }

    /// Where the lines are made: the realization rect and one of its heights above and below it, so a scroll
    /// finds its lines already made; nil (the whole list) while the list has no realization rect.
    func lineWindow() -> NSRect? {
        let realize = realizationRect()
        return realize.isNull ? nil : realize.insetBy(dx: 0, dy: -realize.height)
    }

    /// The rows `window` reaches, widened to whole top-level groups (the line of every group among them is the one a
    /// pass over every row makes), and the row under the last of them when that last row is a group header: its
    /// line's top stops at the row under it. `edge` is that row's group when the row is a header itself: the
    /// caller drops its line, which these rows hold only the start of.
    func lineRows(_ layout: SidebarLayout, around window: NSRect?) -> (rows: ArraySlice<SidebarRow>, edge: GroupID?) {
        guard let window, !layout.rows.isEmpty else { return (layout.rows[...], nil) }
        let colors = lineColors
        func top(_ row: SidebarRow) -> GroupID? {
            var id: GroupID? = if case let .group(header) = row.key { header } else { row.group }
            var seen = Set<GroupID>()
            while let current = id, let parent = colors[current]?.parent, seen.insert(current).inserted { id = parent }
            return id
        }
        let shown = layout.rowIndices(from: window.minY, to: window.maxY)
        var start = shown.first ?? layout.lastIndex(startingAtOrBefore: window.minY) ?? 0
        var end = (shown.last ?? start) + 1
        if let group = top(layout.rows[start]) { while start > 0, top(layout.rows[start - 1]) == group { start -= 1 } }
        if let group = top(layout.rows[end - 1]) { while end < layout.rows.count, top(layout.rows[end]) == group { end += 1 } }
        guard end < layout.rows.count, layout.rows[end - 1].key.isGroupHeader else { return (layout.rows[start..<end], nil) }
        let below = layout.rows[end]
        let edge: GroupID? = if case let .group(id) = below.key { id } else { nil }
        return (layout.rows[start...end], edge)
    }

    /// After a scroll past `lineCover`: the lines of the groups now near the visible rows, each that has none shown at
    /// once at its frame. Lines already shown, moving or not, stay as they are.
    func showLinesInView() {
        let realize = realizationRect()
        guard let cover = lineCover, !realize.isNull, realize.minY < cover.minY || realize.maxY > cover.maxY else { return }
        groupLineViews.showMissing(groupLines(displayed), in: self, above: decorations)
    }

    /// The groups as their lines draw them: with `sidebar.showColors` off every group has no color, so each draws
    /// its block (`SidebarGroupLine.isBlock`) as a group nobody colored does.
    /// Under the gradient palette, a placed group's line takes its place's color (`drawnTints`), as its header does.
    var lineColors: [GroupID: SidebarGroup] {
        guard model.showsColors else {
            return groups.mapValues { group in
                var group = group
                group.tint = .none
                return group
            }
        }
        guard !drawnTints.isEmpty else { return groups }
        var colored = groups
        for (id, tint) in drawnTints { colored[id]?.tint = tint }
        return colored
    }
}

extension SidebarGroupLine {
    /// Every open group in `rows` with shown members: its line from its header to the last member row's bottom,
    /// Chrome's shape (Leo 2026-10-19): 2 pt (`SidebarStyle.groupBarWidth`), one capsule (`SidebarGroupLineShape`), a cut
    /// (`SidebarStyle.groupLineCut`, never past the top of the row under the header) below the bar, or out of the bar's square corner when `joined` under the solid
    /// band (`joinsBar`); just left of the members' rows (`SidebarStyle.groupLineX`), so no row fill covers it
    /// (cx-q5jw: straight and unbroken, Edge style). `frame` places a row.
    /// With `nested` off, the rails before the nested-groups prototype: one per group, ending at its own
    /// last member, at full strength (the "before" capture).
    /// A header's bar reaches left of its own members' x over the line (`SidebarStyle.groupRailReach`): the line
    /// starts at the header frame's left edge, the bar's.
    /// A group with no color (`blocks`, unless `sidebar.noColorGroup` is plain) draws its block instead: from its header's
    /// top to its last shown member's bottom, the header's width, a collapsed group's header alone (Leo 2026-11-05: "a
    /// grouped up thing", with no hue and no indent).
    static func lines(_ rows: [SidebarRow], colors: [GroupID: SidebarGroup], nested: Bool = true,
                      layout: SidebarGroupLineLayout = SidebarStyle.groupLineLayout, joinsBar: Bool = SidebarGroupLine.joinsBar,
                      blocks: Bool = SidebarNoColorGroupLook.tunable.value != .plain,
                      frame: (SidebarRow) -> CGRect) -> [SidebarGroupLine] {
        var headers: [(GroupID, SidebarRow)] = []
        // Groups drawn as their one member's row (`SidebarRow.standsForGroup`): a line along that row, no header.
        var soles: [(GroupID, SidebarRow)] = []
        var last: [GroupID: SidebarRow] = [:]
        // Each group's last row of any kind, its Done, Archived and Show more rows too: a block runs to it (the rail keeps
        // ending at the last member, `last`).
        var lastAny: [GroupID: SidebarRow] = [:]
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
            if let group = row.group, drawn.contains(group) {
                var current: GroupID? = group
                var seen = Set<GroupID>()
                while let id = current, drawn.contains(id), seen.insert(id).inserted {
                    lastAny[id] = row
                    current = nested ? colors[id]?.parent : nil
                }
            }
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
        func tint(_ id: GroupID, _ row: SidebarRow) -> GroupTint { colors[id]?.tint ?? row.groupColor.map(GroupTint.palette) ?? .none }
        func block(_ id: GroupID, _ head: CGRect, _ tail: CGRect, level: Int) -> SidebarGroupLine {
            SidebarGroupLine(group: id, frame: CGRect(x: head.minX, y: head.minY, width: max(head.maxX, tail.maxX) - head.minX,
                                                      height: max(head.maxY, tail.maxY) - head.minY),
                             color: .none, level: level, isBlock: true)
        }
        let soleLines = soles.map { id, row in
            let head = frame(row), tail = frame(last[id] ?? row), bar = SidebarStyle.groupBarX(membersMinX: head.minX)
            if blocks, tint(id, last[id] ?? row).isNone {
                return block(id, head, frame(lastAny[id] ?? last[id] ?? row), level: nested ? max(0, row.depth - 1) : 0)
            }
            let x = layout == .inside ? max(bar, SidebarStyle.groupLineX(membersMinX: head.minX)) : bar
            return SidebarGroupLine(group: id, frame: CGRect(x: x, y: head.minY,
                                                             width: width, height: tail.maxY - head.minY),
                                    color: colors[id]?.tint ?? row.groupColor.map(GroupTint.palette) ?? .none, level: nested ? max(0, row.depth - 1) : 0)
        }
        return soleLines + headers.compactMap { id, header in
            if blocks, tint(id, last[id] ?? header).isNone {
                let end = header.isCollapsed ? header : [lastAny[id], last[id]].compactMap { $0 }.max { $0.y < $1.y } ?? header
                return block(id, frame(header), frame(end), level: nested ? header.depth : 0)
            }
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
                                    color: colors[id]?.tint ?? end.groupColor.map(GroupTint.palette) ?? .none, level: nested ? header.depth : 0)
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
