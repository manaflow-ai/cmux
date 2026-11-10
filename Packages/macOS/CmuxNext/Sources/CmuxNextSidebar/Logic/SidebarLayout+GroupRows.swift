import CoreGraphics

// A group's rows, as `make` lays them out: its header (or the one row it draws as), its members, its folds. One
// function for `make` and for a drag's look (`SidebarDragLook`), which lays out only the group a slot is in.
nonisolated extension SidebarLayout {
    /// The drop gap, when it opens at `section`, `group`, `index` and has not opened yet: it starts at `y`, which
    /// moves past it.
    static func openGap(section: SectionID, group: GroupID?, index: Int, options o: SidebarLayoutOptions, height: CGFloat,
                        metrics m: SidebarLayoutMetrics, y: inout CGFloat, gapY: inout CGFloat?) {
        guard gapY == nil, let gap = o.gap, gap.section == section, gap.group == group, gap.index == index else { return }
        gapY = y
        y += height + m.rowSpacing
    }

    /// Appends `group`'s rows at `y`: node `index` of `section`, with `children` its workspaces the list shows.
    /// `hasSubgroups`: a group of the section sits in it. `gapHeight`: the drop gap's height, as `make` resolved it.
    static func appendGroup(_ group: SidebarGroup, children: [SidebarWorkspace], index: Int, section: SectionID, hasSubgroups: Bool,
                            filtering: Bool, machine machineLabel: String?, options o: SidebarLayoutOptions, metrics m: SidebarLayoutMetrics,
                            gapHeight: CGFloat, to rows: inout [SidebarRow], y: inout CGFloat, gapY: inout CGFloat?) {
        func openGapIfNeeded(_ index: Int) {
            openGap(section: section, group: group.id, index: index, options: o, height: gapHeight, metrics: m, y: &y, gapY: &gapY)
        }
        // The member rows in document order: workspaces with the group's link, tab and app items
        // (an item matches no workspace filter; a dragged item leaves its slot).
        let shown = Set(children.map(\.id))
        let members = group.members.filter { member in
            switch member {
            case let .workspace(ws): shown.contains(ws.id)
            case let .item(item): !filtering && item.id != o.excludedItem
            }
        }
        let groupCollapsed = group.isCollapsed && !filtering
        // One member named as its group (`acpmux new --group X` names both X): the member's row alone, in
        // the header's place, where it draws as a live row (`SidebarLayout+SoleMember`).
        if let sole = soleMember(group, members, hasSubgroups: hasSubgroups, options: o),
           let depth = liveDepth(of: sole, members, in: group, collapsed: groupCollapsed,
                                 fold: SidebarDoneFoldID(section: section, group: group.id), options: o) {
            y = appendSoleMember(sole, of: group, treeDepth: depth, section: section,
                                 parent: index, machine: machineLabel, options: o, metrics: m, to: &rows, y: y)
            // A drop gap in the group opens under the row, as it opened under the header: the row keeps the header's
            // slot under the pointer, and the header never returns mid-drag.
            openGapIfNeeded(0)
            openGapIfNeeded(1)
            return
        }
        var header = SidebarRow(
            key: .group(group.id), y: y, height: m.groupHeaderHeight, section: section,
            group: group.id, siblingIndex: index, parentIndex: nil, isLastInGroup: false,
            isCollapsed: groupCollapsed, childCount: members.count, groupColor: group.color
        )
        header.depth = group.depth
        rows.append(header)
        // Every row appended below is this group's member: one level in from its header.
        let memberRowsStart = rows.count
        defer { for i in memberRowsStart..<rows.count { rows[i].depth = group.depth + 1 } }
        y += m.groupHeaderHeight + m.rowSpacing
        if groupCollapsed {
            // The selected workspace, and one selected here before, stay visible members of a collapsed
            // group: orientation without reopening it, and a click elsewhere removes no row.
            let kept = members.indices.compactMap { i -> (Int, SidebarWorkspace)? in
                guard case let .workspace(member) = members[i], o.shown(inCollapsed: group.id).contains(member.id) else { return nil }
                return children.first(where: { $0.id == member.id }).map { (i, $0) }
            }
            for (n, (childIndex, ws)) in kept.enumerated() {
                let content = o.rowContent(ws, machine: machineLabel)
                let h = m.height(for: content)
                rows.append(SidebarRow(key: .workspace(ws.id), y: y, height: h, section: section, group: group.id,
                                       siblingIndex: childIndex, parentIndex: index, isLastInGroup: n == kept.count - 1,
                                       isCollapsed: false, childCount: 0, groupColor: group.color, content: content))
                y += h + m.rowSpacing
            }
            return
        }
        let fold = SidebarDoneFoldID(section: section, group: group.id)
        let drawn = foldingDone(treeOrder(workspaceIDs(members), parents: o.sessionTree?.parents),
                                workspace: { if case let .workspace(ws) = members[$0] { ws } else { nil } }, fold: fold,
                                project: group, options: o)
        let foldedGap = gapEntry(drawn, gap: o.gap, section: section, group: group.id, count: members.count)
        for (position, (childIndex, depth)) in drawn.enumerated() {
            if childIndex == foldedGap, let gap = o.gap { openGapIfNeeded(gap.index) }
            if childIndex < 0 {
                appendFold(childIndex, fold, count: depth, parent: index, color: group.color, last: position == drawn.count - 1,
                           options: o, to: &rows, y: &y, metrics: m)
                continue
            }
            let member = members[childIndex]
            openGapIfNeeded(childIndex)
            guard case let .workspace(ws) = member else {
                guard case let .item(item) = member else { continue }
                // A link, tab or app member: the listed item's row (`.item`), indented under the group's line.
                let content = WorkspaceRowContent()
                let h = m.height(for: content)
                rows.append(SidebarRow(
                    key: .item(item.id), y: y, height: h, section: section,
                    group: group.id, siblingIndex: childIndex, parentIndex: index,
                    isLastInGroup: position == drawn.count - 1,
                    isCollapsed: false, childCount: 0, groupColor: group.color, content: content
                ))
                y += h + m.rowSpacing
                continue
            }
            var content = o.rowContent(ws, machine: machineLabel)
            content.treeDepth = depth
            let h = m.height(for: content)
            rows.append(SidebarRow(
                key: .workspace(ws.id), y: y, height: h, section: section,
                group: group.id, siblingIndex: childIndex, parentIndex: index,
                isLastInGroup: position == drawn.count - 1,
                isCollapsed: false, childCount: 0, groupColor: group.color, content: content
            ))
            y += h + m.rowSpacing
        }
        // The next row follows the last member by the row spacing alone (Leo 2026-10-21: no padding after groups).
        openGapIfNeeded(members.count)
    }
}
