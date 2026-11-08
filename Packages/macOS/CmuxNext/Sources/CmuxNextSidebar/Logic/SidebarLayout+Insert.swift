import CoreGraphics

// SIDEBAR INSERT 2 (profile cmux21, macOS 27, 120 Hz: Cmd-N's key turn laid every row out again for its one new row,
// `SidebarLayout.make` 1.1 ms at 50 rows and 4.6 ms at 200). A create's row is one loose workspace row: the layout the
// list shows takes it spliced in at its place, as `make` would lay it out, and the rows under it move down by its slot
// (one vector add of their y, as a group's fold). No other row is built again, so the cost is the new row's.
nonisolated extension SidebarLayout {
    /// Splices `insertion`'s workspace row into this layout, as `make(sections:metrics:options:)` lays it out with the
    /// row added to the sections; the rows after it move down by its slot and the section's later rows count one more
    /// node before them. False (unchanged) when the row cannot be spliced and the list must be laid out again: a
    /// filter, a drag, Group by Status, Folder or Recents, the session tree, a row limit, the chat history, a row that
    /// folds (Done, archived), a section that showed no row, or no drawn neighbour row to place it by.
    ///
    /// - Parameters:
    ///   - insertion: The set that added the row (its section as the set left it, and the row's node index).
    ///   - base: The list's metrics (`options.minimal` makes them minimal, as in `make`).
    ///   - o: The options the list lays out with; the layout was made with the same ones.
    mutating func insertLoose(_ insertion: SidebarRowInsertion, metrics base: SidebarLayoutMetrics, options o: SidebarLayoutOptions) -> Bool {
        let section = insertion.section, k = insertion.node
        guard let ws = insertion.workspace, o.filterMatches == nil, o.gap == nil, gapY == nil, o.excludedGroup == nil,
              o.excludedItem == nil, !o.excludedWorkspaces.contains(ws.id), !o.grouping.isGrouped, !o.hidesWorkspaces,
              o.sessionTree == nil, o.rowLimit == 0, pinnedChatsY == nil, earlierChatsY == nil,
              section.machine != nil, !section.isDocSection, !Self.folds(ws, o),
              position(of: .workspace(ws.id)) == nil else { return false }
        // Where `make` puts node k: right before the row of the node after it, or right after the row of the loose
        // node before it. Each must be its node's own row at the top level of the section (not a fold, a group's member
        // or a group drawn as its one member) and drawn in node order (not behind a "Done" or "Archived" row).
        let nodes = section.nodes
        var at: Int?, y: CGFloat = 0, sibling = 0
        if k + 1 < nodes.count, !Self.folds(nodes[k + 1], o), let next = position(of: Self.rowKey(nodes[k + 1])),
           Self.isOwnTopRow(rows[next], in: section) {
            (at, y, sibling) = (next, rows[next].y, rows[next].siblingIndex)
        } else if k > 0, !Self.folds(nodes[k - 1], o), Self.isLoose(nodes[k - 1]), let previous = position(of: Self.rowKey(nodes[k - 1])),
                  Self.isOwnTopRow(rows[previous], in: section) {
            (at, y, sibling) = (previous + 1, rows[previous].maxY + rowSpacing, rows[previous].siblingIndex + 1)
        }
        // An anchor under "Archive (N)" is an archived group's row there (`appendArchive`), not its node's place.
        guard let at, position(of: .doneFold(.archive)).map({ at <= $0 }) ?? true else { return false }
        let m = base.resolved(for: o)
        guard m.rowSpacing == rowSpacing else { return false }
        let content = o.rowContent(ws, machine: Self.machineLabel(section, options: o))
        let h = m.height(for: content)
        let row = SidebarRow(
            key: .workspace(ws.id), y: y, height: h, section: section.id,
            group: nil, siblingIndex: sibling, parentIndex: nil, isLastInGroup: false,
            isCollapsed: false, childCount: 0, groupColor: nil, content: content
        )
        replaceRows(at..<at, with: [row], shiftingFollowingBy: h + m.rowSpacing)
        // The section's later rows: a top-level row's node index, and a member's group index, count the new node.
        var i = at + 1
        while i < rows.count, rows[i].section == section.id {
            var later = rows[i], moved = false
            switch later.key {
            case .doneFold, .showMore: break // a fold row's index is no node's
            default:
                if later.parentIndex == nil, later.siblingIndex >= sibling { (later.siblingIndex, moved) = (later.siblingIndex + 1, true) }
            }
            if let parent = later.parentIndex, parent >= sibling { (later.parentIndex, moved) = (parent + 1, true) }
            if moved { setRow(later, at: i) }
            i += 1
        }
        // The section's header counts its nodes.
        if let header = position(of: .section(section.id)) {
            var counted = rows[header]
            counted.childCount += 1
            setRow(counted, at: header)
        }
        SidebarPerfCounters.add(.layoutRows)
        return true
    }

    /// Whether `ws` is drawn behind a fold row (Done, archived), out of node order.
    private static func folds(_ ws: SidebarWorkspace, _ o: SidebarLayoutOptions) -> Bool {
        ws.isArchived || (o.foldsDone && ws.taskStatus == .done)
    }

    private static func folds(_ node: SidebarNode, _ o: SidebarLayoutOptions) -> Bool {
        switch node {
        case let .workspace(ws): folds(ws, o)
        case let .item(item): item.isArchived
        case .group: false
        }
    }

    private static func isLoose(_ node: SidebarNode) -> Bool {
        if case .group = node { false } else { true }
    }

    /// The row key `make` gives a node's own row.
    private static func rowKey(_ node: SidebarNode) -> SidebarRowKey {
        switch node {
        case let .workspace(ws): .workspace(ws.id)
        case let .group(group): .group(group.id)
        case let .item(item): .item(item.id)
        }
    }

    /// `row` is a top-level row of `section` drawn for its own node (a group's header, a loose row), not a member.
    private static func isOwnTopRow(_ row: SidebarRow, in section: SidebarSection) -> Bool {
        row.section == section.id && row.parentIndex == nil && row.depth == 0 && !row.standsForGroup
    }
}
