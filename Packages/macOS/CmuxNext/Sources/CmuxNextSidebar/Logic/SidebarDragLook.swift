import CoreGraphics

// SIDEBAR DRAG LOOK: a workspace drag that retargets draws the list with the dragged rows at the new slot. That look
// was `SidebarLayout.make` of the moved sections, every row laid out again for each new slot (rows=5000: 87 of a
// 93 ms retarget, growing with the rows; Leo 2026-11-04: "It should just never, ever ... be acceptable for there to be
// some sort of linear time growth degradation"). The drag's base layout already holds every row the move leaves
// alone: it is the list without the dragged rows, and a move only takes them out of where they were (which the base
// already shows) and puts them in at the slot. So the look is the base with the slot's container laid out again (the
// group the slot is in), or the dragged rows put in among a section's top-level rows, and the rows after it moved by
// the difference (one vector add of their y, as a fold). The cost is the rows of that container plus one copy and one
// y add over the list (`SidebarDragFullMoveCostTests`).
/// A workspace drag's look, spliced from the drag's base layout (`SidebarListView.dragBase` makes it once per base).
nonisolated struct SidebarDragLook {
    /// The list without the dragged rows, as the drag's base lays it out.
    let base: SidebarLayout
    /// The sections the base was made from.
    let sections: [SidebarSection]
    /// The options the look lays out with: the base's, with the dragged rows shown (`shown(_:leaving:)`).
    let options: SidebarLayoutOptions
    /// The dragged workspaces in document order, the order a move takes them out in (`SidebarEdits.removeWorkspaces`),
    /// with the section they leave and the group they leave (nil: a loose row).
    private let moving: [(ws: SidebarWorkspace, section: Int, group: GroupID?)]
    private let ids: Set<WorkspaceID>
    /// Each group's section and node index.
    private let groups: [GroupID: (section: Int, node: Int)]
    /// The groups a group of the list sits in.
    private let subgroupParents: Set<GroupID>
    /// Sections with a group under a collapsed one: `make` leaves such a group out of the node count, so a top-level
    /// row's index there is not its node's.
    private let hidingSections: Set<SectionID>
    /// With the Archive section drawn: groups that are archived, hold an archived workspace, or sit in such a group.
    /// A move in or out of one may move it to the Archive or keep it there (`splittingArchive`).
    private let archiveBound: Set<GroupID>
    /// The loose dragged rows each section loses.
    private let looseLeaving: [Int: Int]
    /// Each section's rows in the base, where they are one run.
    private let sectionRows: [SectionID: Range<Int>]
    /// Whether any slot of this drag may splice: false for a state the splice does not lay out as `make` does.
    private let splices: Bool

    /// The look's options for a list that lays its drag's base out with `o`: the dragged rows shown, only the rows
    /// that are leaving the list (`leaving`) left out.
    static func shown(_ o: SidebarLayoutOptions, leaving: Set<WorkspaceID>) -> SidebarLayoutOptions {
        var shown = o
        (shown.excludedWorkspaces, shown.excludedGroup, shown.excludedItem) = (leaving, nil, nil)
        return shown
    }

    /// One pass over the sections and the base's rows, once per drag base.
    init(base: SidebarLayout, sections: [SidebarSection], options: SidebarLayoutOptions, moving dragged: [WorkspaceID]) {
        let wanted = Set(dragged)
        let archive = SidebarLayout.drawsArchiveSection(options)
        var seen = Set<WorkspaceID>(), repeats = false
        var moving: [(ws: SidebarWorkspace, section: Int, group: GroupID?)] = []
        var groups: [GroupID: (section: Int, node: Int)] = [:]
        var parents = Set<GroupID>(), hiding = Set<SectionID>(), bound = Set<GroupID>()
        var looseLeaving: [Int: Int] = [:]
        for (s, section) in sections.enumerated() {
            var hidden = Set<GroupID>()
            for (n, node) in section.nodes.enumerated() {
                switch node {
                case let .workspace(ws):
                    if !seen.insert(ws.id).inserted { repeats = true }
                    if wanted.contains(ws.id) {
                        moving.append((ws, s, nil))
                        looseLeaving[s, default: 0] += 1
                    }
                case let .group(group):
                    groups[group.id] = (s, n)
                    if let parent = group.parent {
                        parents.insert(parent)
                        if hidden.contains(parent) {
                            hidden.insert(group.id)
                            hiding.insert(section.id)
                        }
                    }
                    if group.isCollapsed { hidden.insert(group.id) }
                    if archive, group.isArchived || group.workspaces.contains(where: \.isArchived) || group.parent.map(bound.contains) == true {
                        bound.insert(group.id)
                    }
                    for ws in group.workspaces {
                        if !seen.insert(ws.id).inserted { repeats = true }
                        if wanted.contains(ws.id) { moving.append((ws, s, group.id)) }
                    }
                case .item:
                    break
                }
            }
        }
        // Each section's rows: a section whose rows are not one run (the Archive row is Pinned's) has none.
        var ranges: [SectionID: Range<Int>] = [:], broken = Set<SectionID>()
        var i = 0
        while i < base.rows.count {
            let id = base.rows[i].section
            var j = i + 1
            while j < base.rows.count, base.rows[j].section == id { j += 1 }
            if ranges[id] == nil { ranges[id] = i..<j } else { broken.insert(id) }
            i = j
        }
        for id in broken { ranges[id] = nil }
        let o = options
        let emptiesASection = looseLeaving.contains { sections[$0.key].nodes.count == $0.value }
        self.base = base
        self.sections = sections
        self.options = options
        self.moving = moving
        ids = wanted
        self.groups = groups
        subgroupParents = parents
        hidingSections = hiding
        archiveBound = bound
        self.looseLeaving = looseLeaving
        sectionRows = ranges
        splices = !moving.isEmpty && !repeats && !emptiesASection && !moving.contains { $0.group.map(bound.contains) == true }
            && o.filterMatches == nil && !o.grouping.isGrouped && o.sessionTree == nil && o.chatHistory == nil && o.rowLimit == 0
            && !o.hidesWorkspaces && o.gap == nil && o.excludedWorkspaces.isEmpty && o.excludedGroup == nil && o.excludedItem == nil
            && base.gapY == nil && base.pinnedChatsY == nil && base.earlierChatsY == nil
    }

    /// The look with the dragged rows at `position` (in the base's coordinates, as the drop resolver names it), as
    /// `make` lays out the sections the move makes (`SidebarEdits.reorder`, `prunes: false`), with the slot's gap
    /// (`gapY`, `gapShift`) over the dragged rows. Nil when the splice cannot lay it out as `make` does; the list lays
    /// it out in full then: a filter, Group by Status, Folder or Recents, the session tree, a row limit, the chat
    /// history, a leaving row, a workspace listed twice, a move `reorder` refuses (another machine's section, a group
    /// outside a machine), a section the move empties or that is empty, a group in or near the Archive, a document
    /// section, and for a top-level slot a section with a top-level Done or Archived fold, a folded header or a group
    /// under a collapsed one; for a slot in a group, a group the base does not draw.
    func layout(to position: DropPosition, metrics: SidebarLayoutMetrics) -> SidebarLayout? {
        guard splices, let s = sections.firstIndex(where: { $0.id == position.section }) else { return nil }
        let section = sections[s]
        // The moves `reorder` refuses leave the rows where they were.
        if position.group != nil, section.machine == nil { return nil }
        guard moving.allSatisfy({ SidebarEdits.canPlace($0.ws, in: section) }) else { return nil }
        // A section the move leaves with no node, or that had none: `make` draws it empty, or not at all.
        guard section.nodes.count - (looseLeaving[s] ?? 0) > 0 else { return nil }
        let m = metrics.resolved(for: options)
        guard m.rowSpacing == base.rowSpacing else { return nil }
        let spliced = if let group = position.group {
            intoGroup(group, at: position.index, section: s, metrics: m)
        } else {
            loose(at: position.index, section: s, metrics: m)
        }
        guard let spliced else { return nil }
        return gapped(spliced.layout, spliced.slot, metrics: metrics)
    }

    /// The base with group `id`'s rows laid out again with the dragged rows among its members at `index`.
    private func intoGroup(_ id: GroupID, at index: Int, section s: Int, metrics m: SidebarLayoutMetrics) -> (layout: SidebarLayout, slot: Range<Int>)? {
        guard let listed = groups[id], listed.section == s, !archiveBound.contains(id),
              case var .group(group) = sections[s].nodes[listed.node] else { return nil }
        let kept = group.members.filter { if case let .workspace(ws) = $0 { !ids.contains(ws.id) } else { true } }
        var members = kept
        members.insert(contentsOf: moving.map { SidebarGroupMember.workspace($0.ws) }, at: max(0, min(index, members.count)))
        group.setMembers(members)
        // The group's rows in the base: its header (or the one row it draws as) and every row of it under that.
        guard let start = groupStart(id, kept) else { return nil }
        var end = start + 1
        while end < base.rows.count, base.rows[end].group == id { end += 1 }
        let first = base.rows[start]
        let node = first.standsForGroup ? (first.parentIndex ?? first.siblingIndex) : first.siblingIndex
        var rows: [SidebarRow] = []
        var y = first.y
        var gapY: CGFloat?
        SidebarLayout.appendGroup(group, children: group.workspaces.filter(options.visible), index: node, section: sections[s].id,
                                  hasSubgroups: subgroupParents.contains(id), filtering: false,
                                  machine: SidebarLayout.machineLabel(sections[s], options: options), options: options, metrics: m,
                                  gapHeight: 0, to: &rows, y: &y, gapY: &gapY)
        var layout = base
        layout.replaceRows(start..<end, with: rows, shiftingFollowingBy: y - (base.rows[end - 1].maxY + m.rowSpacing))
        SidebarPerfCounters.add(.layoutRows, rows.count)
        return (layout, start..<start + rows.count)
    }

    /// Where group `id`'s rows start in the base: its header, or the one row it draws as with its members `kept`.
    private func groupStart(_ id: GroupID, _ kept: [SidebarGroupMember]) -> Int? {
        if let header = base.position(of: .group(id)) { return header }
        guard kept.count == 1, case let .workspace(only) = kept[0], let row = base.position(of: .workspace(only.id)),
              base.rows[row].standsForGroup, base.rows[row].group == id else { return nil }
        return row
    }

    /// The base with the dragged rows as loose rows of section `s` at node `index`, the section's later rows
    /// counting them.
    private func loose(at index: Int, section s: Int, metrics m: SidebarLayoutMetrics) -> (layout: SidebarLayout, slot: Range<Int>)? {
        let section = sections[s]
        guard !section.isDocSection, !hidingSections.contains(section.id), let range = sectionRows[section.id] else { return nil }
        // A section that draws its rows out of node order (a Done or Archived fold at its end), folded, or as its empty
        // drop zone.
        for kind in [SidebarDoneFoldID.Kind.done, .archived]
            where base.position(of: .doneFold(SidebarDoneFoldID(section: section.id, group: nil, kind: kind))) != nil { return nil }
        let header = base.position(of: .section(section.id))
        if let header, base.rows[header].isCollapsed { return nil }
        guard base.position(of: .emptySection(section.id)) == nil else { return nil }
        let q = max(0, min(index, section.nodes.count - (looseLeaving[s] ?? 0)))
        // The first row of node q or after it: the section's rows run in node order.
        var (low, high) = (range.lowerBound, range.upperBound)
        while low < high {
            let mid = (low + high) / 2
            if Self.node(of: base.rows[mid]) < q { low = mid + 1 } else { high = mid }
        }
        let at = low
        let top = at < range.upperBound ? base.rows[at].y : base.rows[at - 1].maxY + m.rowSpacing
        let label = SidebarLayout.machineLabel(section, options: options)
        var rows: [SidebarRow] = []
        var y = top
        for (j, entry) in moving.enumerated() {
            var content = options.rowContent(entry.ws, machine: label)
            (content.treeDepth, content.treeFold, content.rollUp) = (0, nil, nil)
            let h = m.height(for: content)
            rows.append(SidebarRow(
                key: .workspace(entry.ws.id), y: y, height: h, section: section.id,
                group: nil, siblingIndex: q + j, parentIndex: nil, isLastInGroup: false,
                isCollapsed: false, childCount: 0, groupColor: nil, content: content
            ))
            y += h + m.rowSpacing
        }
        let k = rows.count
        var layout = base
        layout.replaceRows(at..<at, with: rows, shiftingFollowingBy: y - top)
        // The section's later rows: a top-level row's node index, and a member's group index, count the new nodes.
        layout.updateRows(at + k..<range.upperBound + k) { later in
            switch later.key {
            case .doneFold, .showMore: break // a fold row's index is no node's
            default: if later.parentIndex == nil, later.siblingIndex >= q { later.siblingIndex += k }
            }
            if let parent = later.parentIndex, parent >= q { later.parentIndex = parent + k }
        }
        // The section's header counts its nodes.
        if let header { layout.updateRows(header..<header + 1) { $0.childCount += k } }
        SidebarPerfCounters.add(.layoutRows, k)
        return (layout, at..<at + k)
    }

    /// The node a row of a section belongs to (its own, or its group's); the header, and one list's "Workspaces"
    /// heading, come before every node.
    private static func node(of row: SidebarRow) -> Int {
        switch row.key {
        case .section, .listHeader: return -1
        default: break
        }
        return row.parentIndex ?? row.siblingIndex
    }

    /// `layout` with the gap the dragged rows (in `slot`) make: where `DropResolver` maps display y back to base y.
    private func gapped(_ layout: SidebarLayout, _ slot: Range<Int>, metrics: SidebarLayoutMetrics) -> SidebarLayout {
        var layout = layout
        let dragged = layout.rows[slot].filter { if case let .workspace(id) = $0.key { ids.contains(id) } else { false } }
        if let first = dragged.first, let last = dragged.last {
            layout.gapY = first.y
            layout.gapShift = last.maxY + metrics.rowSpacing - first.y
        }
        return layout
    }
}
