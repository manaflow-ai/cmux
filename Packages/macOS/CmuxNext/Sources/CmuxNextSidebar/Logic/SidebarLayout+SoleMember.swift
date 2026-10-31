import CoreGraphics

// A group of one workspace titled as the group (Leo 2026-10-29: "why is there all this weird stuff at the bottom of the
// sidebar"): `acpmux new --group X` makes a group X holding one workspace X, so the list said the name twice, a header
// and an indented member under it. Such a group draws one row: the member's, in the header's place and at its indent
// (a member row's level is its header's, `SidebarRow.indentLevel`). The row stays the group's member (`group`, its
// color and line) and stands for the group (`standsForGroup`): its menu carries the group's actions.
nonisolated extension SidebarLayout {
    /// The workspace `group` draws as its one row, or nil when the group keeps its header: two or more members, an
    /// item member, a member named otherwise (names compared trimmed), or subgroups under it.
    static func soleMember(_ group: SidebarGroup, _ members: [SidebarGroupMember], hasSubgroups: Bool) -> SidebarWorkspace? {
        guard members.count == 1, !hasSubgroups, case let .workspace(ws) = members[0] else { return nil }
        return names(group, ws.title) ? ws : nil
    }

    /// Whether `title` is `group`'s name (both trimmed, the name not empty).
    static func names(_ group: SidebarGroup, _ title: String) -> Bool {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && title.trimmingCharacters(in: .whitespacesAndNewlines) == name
    }

    /// The session-tree depth `ws` draws at when it is `group`'s one live row, or nil when the group keeps its header
    /// because the member would not draw as a live row of its own: folded behind the group's "Done (N)" row
    /// (`foldingDone`), or hidden in a collapsed group (only a kept member, `shown(inCollapsed:)`, draws there).
    static func liveDepth(of ws: SidebarWorkspace, _ members: [SidebarGroupMember], in group: SidebarGroup, collapsed: Bool,
                          fold: SidebarDoneFoldID, options o: SidebarLayoutOptions) -> Int? {
        if collapsed { return o.shown(inCollapsed: group.id).contains(ws.id) ? 0 : nil }
        let drawn = foldingDone(treeOrder(workspaceIDs(members), parents: o.sessionTree?.parents), workspace: { _ in ws }, fold: fold, options: o)
        guard drawn.count == 1, drawn[0].index == 0 else { return nil }
        return drawn[0].depth
    }

    /// Appends `ws`'s row (and its inline tabs, unless the group is `collapsed`: a collapsed group's kept member lists
    /// none) at `y` as `group`'s one row and returns the y after it.
    static func appendSoleMember(_ ws: SidebarWorkspace, of group: SidebarGroup, collapsed: Bool, treeDepth: Int, section: SectionID,
                                 parent: Int, machine: String?, options o: SidebarLayoutOptions, metrics m: SidebarLayoutMetrics,
                                 to rows: inout [SidebarRow], y: CGFloat) -> CGFloat {
        var y = y
        var content = o.rowContent(ws, machine: machine)
        content.treeDepth = treeDepth
        let h = m.height(for: content)
        var row = SidebarRow(
            key: .workspace(ws.id), y: y, height: h, section: section,
            group: group.id, siblingIndex: 0, parentIndex: parent, isLastInGroup: true,
            isCollapsed: false, childCount: 0, groupColor: group.color,
            tabDisclosure: o.disclosure(ws), content: content
        )
        row.depth = group.depth + 1
        row.standsForGroup = true
        rows.append(row)
        y += h + m.rowSpacing
        guard !collapsed, o.listsTabs(ws) else { return y }
        for tab in ws.tabs {
            var tabRow = SidebarRow(
                key: .tab(ws.id, tab.id), y: y, height: m.tabRowHeight, section: section,
                group: group.id, workspace: ws.id, siblingIndex: 0, parentIndex: parent,
                isLastInGroup: false, isCollapsed: false, childCount: 0,
                groupColor: group.color, tabKind: tab.kind
            )
            tabRow.depth = group.depth + 1
            rows.append(tabRow)
            y += m.tabRowHeight + m.rowSpacing
        }
        return y
    }
}

nonisolated extension SidebarLayout {
    /// The row that is `group`'s on screen: its header, or the one row it draws as (`standsForGroup`) when it has none.
    /// Every lookup of a group's row, frame or stop goes through here; nil when the layout shows neither.
    func groupRow(_ group: GroupID) -> SidebarRow? {
        row(for: .group(group)) ?? rows.first { $0.standsForGroup && $0.group == group }
    }
}

nonisolated extension SidebarRow {
    /// The header a group's one row (`standsForGroup`) stands for: the group's open header in the row's place, for code
    /// that plans by headers (the drop resolvers, a group drag's blocks). Nil for any other row.
    var standingHeader: SidebarRow? {
        guard standsForGroup, let group else { return nil }
        var header = self
        (header.key, header.siblingIndex, header.parentIndex, header.depth) = (.group(group), parentIndex ?? siblingIndex, nil, depth - 1)
        (header.workspace, header.isLastInGroup, header.isCollapsed, header.childCount) = (nil, false, false, 1)
        (header.tabDisclosure, header.content, header.standsForGroup) = (nil, nil, false)
        return header
    }
}
