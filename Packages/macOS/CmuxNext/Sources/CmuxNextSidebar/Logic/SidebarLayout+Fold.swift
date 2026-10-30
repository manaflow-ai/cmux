import CoreGraphics

nonisolated extension SidebarLayout {
    /// This layout with `group` folded (`collapsed`) or opened, as `make` would lay it out, spliced in
    /// place: only the group's member rows are built, and the rows after it move by the height change.
    ///
    /// A fold is view state the sidebar owns (plans/cmux-next/state-ownership-DESIGN.md), so it never
    /// waits for the daemon and never lays the whole list out: its cost is the group's rows, not the
    /// list's. Nil when the fold cannot be spliced and the list must be laid out again: a filter, a
    /// drag gap or excluded item, Group by Folder, inline tabs, or a group this layout does not draw.
    ///
    /// - Parameters:
    ///   - group: The group as the model holds it (its members; `isCollapsed` is ignored).
    ///   - collapsed: The fold to show.
    ///   - section: The section that lists the group (its machine names the rows of another computer).
    ///   - base: The list's metrics (`options.minimal` makes them minimal, as in `make`).
    ///   - o: The options the list lays out with.
    func folding(_ group: SidebarGroup, collapsed: Bool, in section: SidebarSection, metrics base: SidebarLayoutMetrics,
                 options o: SidebarLayoutOptions) -> SidebarLayout? {
        var next = self
        return next.fold(group, collapsed: collapsed, in: section, metrics: base, options: o) ? next : nil
    }

    /// `folding`, in place: no copy of the rows when this layout is the only holder of them. False (unchanged) when
    /// the fold cannot be spliced.
    mutating func fold(_ group: SidebarGroup, collapsed: Bool, in section: SidebarSection, metrics base: SidebarLayoutMetrics,
                       options o: SidebarLayoutOptions) -> Bool {
        guard o.filterMatches == nil, o.gap == nil, gapY == nil, o.excludedGroup == nil, o.excludedItem == nil,
              !o.showWorkspaceTabs, !o.grouping.isGrouped, !o.hidesWorkspaces,
              let headerIndex = position(of: .group(group.id)) else { return false }
        // The chat history's blocks sit at places the full layout leaves (`pinnedChatsY`, `earlierChatsY`); a splice
        // moves the rows but not those places, so with history shown the list is laid out again.
        guard pinnedChatsY == nil, earlierChatsY == nil else { return false }
        // A nested group or a group holding subgroups (remote-groups-DESIGN.md slice 2): its block holds other groups'
        // rows, so the full layout places them.
        // A group holding workspaces marked Done draws them behind its "Done (N)" row (`foldingDone`): laid out again.
        // So does one longer than the row limit (its "Show N more" row).
        // So does one whose members nest under each other (the session tree's lineage: `treeRows` orders them).
        guard group.parent == nil, !(o.foldsDone && group.workspaces.contains { $0.taskStatus == .done }),
              !(o.sessionTree.map { tree in group.workspaces.contains { tree.parents[$0.id] != nil } } ?? false),
              o.rowLimit == 0 || group.members.count <= o.rowLimit + 1,
              !section.nodes.contains(where: { if case let .group(child) = $0 { child.parent == group.id } else { false } }) else { return false }
        let m = base.resolved(for: o)
        let header = rows[headerIndex]
        guard header.section == section.id else { return false }
        // The group's block: its header and the member rows right after it.
        var end = headerIndex + 1
        while end < rows.count, rows[end].group == group.id, !rows[end].key.isGroupHeader { end += 1 }
        let oldEnd = Self.blockEnd(header: header, last: end > headerIndex + 1 ? rows[end - 1] : nil, metrics: m)

        let shown = group.workspaces.filter { !o.excludedWorkspaces.contains($0.id) }
        let shownIDs = Set(shown.map(\.id))
        let members = group.members.filter { member in
            switch member {
            case let .workspace(ws): shownIDs.contains(ws.id)
            case .item: true
            }
        }
        guard members.count == header.childCount else { return false } // the members changed too: a structural change
        let machineLabel = Self.machineLabel(section, options: o)
        let parent = header.siblingIndex
        var built: [SidebarRow] = []
        var y = header.maxY + m.rowSpacing
        // Members sit one level in from their header (`make`).
        let memberDepth = group.depth + 1
        func workspaceRow(_ ws: SidebarWorkspace, at childIndex: Int, last: Bool) {
            let content = o.rowContent(ws, machine: machineLabel)
            let h = m.height(for: content)
            built.append(SidebarRow(
                key: .workspace(ws.id), y: y, height: h, section: section.id,
                group: group.id, siblingIndex: childIndex, parentIndex: parent,
                isLastInGroup: last, isCollapsed: false, childCount: 0,
                groupColor: group.color, tabDisclosure: nil, content: content
            ))
            built[built.count - 1].depth = memberDepth
            y += h + m.rowSpacing
        }
        if collapsed {
            // The selected workspace, and one selected here before, stay visible members (`make`).
            let kept = members.indices.compactMap { i -> (Int, SidebarWorkspace)? in
                guard case let .workspace(member) = members[i], o.shown(inCollapsed: group.id).contains(member.id) else { return nil }
                return shown.first(where: { $0.id == member.id }).map { (i, $0) }
            }
            for (n, (childIndex, ws)) in kept.enumerated() { workspaceRow(ws, at: childIndex, last: n == kept.count - 1) }
        } else if members.isEmpty {
            // Subgroups and filters already sent the full layout above; the empty row is `make`'s.
            if Self.listsEmptyRow(group, filtering: false, hasSubgroups: false) {
                y = Self.appendEmptyRow(group, section: section.id, parent: parent, metrics: m, to: &built, y: y)
            }
        } else {
            for (childIndex, member) in members.enumerated() {
                switch member {
                case let .workspace(ws):
                    workspaceRow(ws, at: childIndex, last: childIndex == members.count - 1)
                case let .item(item):
                    let content = WorkspaceRowContent()
                    let h = m.height(for: content)
                    built.append(SidebarRow(
                        key: .item(item.id), y: y, height: h, section: section.id,
                        group: group.id, siblingIndex: childIndex, parentIndex: parent,
                        isLastInGroup: childIndex == members.count - 1,
                        isCollapsed: false, childCount: 0, groupColor: group.color, content: content
                    ))
                    built[built.count - 1].depth = memberDepth
                    y += h + m.rowSpacing
                }
            }
        }
        let newEnd = Self.blockEnd(header: header, last: built.last, metrics: m)
        var folded = header
        folded.isCollapsed = collapsed
        setRow(folded, at: headerIndex)
        replaceRows((headerIndex + 1)..<end, with: built, shiftingFollowingBy: newEnd - oldEnd)
        return true
    }

    /// The rows of `keys` (and of group `id`'s block and its section header), as a small layout: what a fold's
    /// animation reads of the layout before it (old frames, the folding header) without keeping every row.
    func excerpt(_ keys: some Sequence<SidebarRowKey>, group id: GroupID) -> SidebarLayout {
        // Positions, not row copies: the rows are already in y order, so sorting the picked positions orders them,
        // and the group's block (10,000 members in a huge group) is one contiguous range appended once.
        var positions = Set<Int>()
        for key in keys { if let at = position(of: key) { positions.insert(at) } }
        if let start = position(of: .group(id)) {
            positions.insert(start)
            var end = start + 1
            while end < rows.count, rows[end].group == id, !rows[end].key.isGroupHeader { end += 1 }
            positions.formUnion(start..<end)
            if let section = position(of: .section(rows[start].section)) { positions.insert(section) }
        }
        var layout = SidebarLayout(rows: positions.sorted().map { rows[$0] }, totalHeight: totalHeight, gapY: nil, gapHeight: 0, gapShift: 0)
        layout.rowSpacing = rowSpacing
        return layout
    }

    /// Where the list goes on after a group's block (`make`): one row spacing under its last row, open or
    /// folded (no padding under a group, Leo 2026-10-21).
    private static func blockEnd(header: SidebarRow, last: SidebarRow?, metrics m: SidebarLayoutMetrics) -> CGFloat {
        (last ?? header).maxY + m.rowSpacing
    }
}

nonisolated extension SidebarRowKey {
    /// A group's header row.
    var isGroupHeader: Bool { if case .group = self { true } else { false } }
}
