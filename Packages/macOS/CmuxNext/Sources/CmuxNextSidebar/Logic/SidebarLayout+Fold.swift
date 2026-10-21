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
              !o.showWorkspaceTabs, !o.groupsByFolder, !o.hidesWorkspaces,
              let headerIndex = position(of: .group(group.id)) else { return false }
        // A nested group or a group holding subgroups (remote-groups-DESIGN.md slice 2): its block holds other groups'
        // rows, so the full layout places them.
        guard group.parent == nil,
              !section.nodes.contains(where: { if case let .group(child) = $0 { child.parent == group.id } else { false } }) else { return false }
        let m = o.minimal ? base.minimal : base
        let header = rows[headerIndex]
        guard header.section == section.id else { return false }
        // The group's block: its header and the member rows right after it.
        var end = headerIndex + 1
        while end < rows.count, rows[end].group == group.id, !rows[end].key.isGroupHeader { end += 1 }
        let oldEnd = Self.blockEnd(header: header, last: end > headerIndex + 1 ? rows[end - 1] : nil, collapsed: header.isCollapsed, metrics: m)

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
            // The selected workspace stays as the one visible member (`make`).
            if let activeID = o.activeWorkspaceID,
               let childIndex = members.firstIndex(where: { if case let .workspace(ws) = $0 { ws.id == activeID } else { false } }),
               let ws = shown.first(where: { $0.id == activeID }) {
                workspaceRow(ws, at: childIndex, last: true)
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
        let newEnd = Self.blockEnd(header: header, last: built.last, collapsed: collapsed, metrics: m)
        var folded = header
        folded.isCollapsed = collapsed
        setRow(folded, at: headerIndex)
        replaceRows((headerIndex + 1)..<end, with: built, shiftingFollowingBy: newEnd - oldEnd)
        return true
    }

    /// The rows of `keys` (and of group `id`'s block and its section header), as a small layout: what a fold's
    /// animation reads of the layout before it (old frames, the folding header) without keeping every row.
    func excerpt(_ keys: some Sequence<SidebarRowKey>, group id: GroupID) -> SidebarLayout {
        var picked: [SidebarRowKey: SidebarRow] = [:]
        for key in keys { if let row = row(for: key) { picked[key] = row } }
        if let start = position(of: .group(id)) {
            picked[rows[start].key] = rows[start]
            for i in (start + 1)..<rows.count {
                guard rows[i].group == id, !rows[i].key.isGroupHeader else { break }
                picked[rows[i].key] = rows[i]
            }
            if let section = row(for: .section(rows[start].section)) { picked[section.key] = section }
        }
        var layout = SidebarLayout(rows: picked.values.sorted { $0.y < $1.y }, totalHeight: totalHeight, gapY: nil, gapHeight: 0, gapShift: 0)
        layout.rowSpacing = rowSpacing
        return layout
    }

    /// Where the list goes on after a group's block (`make`): an open group adds its bottom padding.
    private static func blockEnd(header: SidebarRow, last: SidebarRow?, collapsed: Bool, metrics m: SidebarLayoutMetrics) -> CGFloat {
        let after = (last ?? header).maxY + m.rowSpacing
        return collapsed ? after : after + m.groupBottomPadding
    }
}

nonisolated extension SidebarRowKey {
    /// A group's header row.
    var isGroupHeader: Bool { if case .group = self { true } else { false } }
}
