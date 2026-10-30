import CoreGraphics

// R77: a drag reorders in place. While the pointer is over a slot, the
// displayed layout already holds the dragged rows there (hidden under the
// lifted view) and the other rows spring out of the way; there is no
// placeholder underlay. On release the model takes the same order, so the
// lifted view settles into a slot that does not move.
extension SidebarListViewComponents {
    /// The layout the list shows: the model's, or during an internal drag
    /// over a slot, the model with the dragged rows moved to that slot.
    func displayLayout() -> SidebarLayout {
        // Over a row's middle the list keeps the last slot (the row highlights instead).
        let drag = shownDrag // the running drag, or a dropped one still settling
        // A group drag draws one function of its frozen base and its slot (`SidebarGroupDragPlan.layout`).
        if let group = drag?.group { return group.layout }
        let shownPosition: DropPosition? = switch drag?.target {
        case let .position(position)?: position
        case .ontoWorkspace?: drag?.lastPosition
        default: nil
        }
        // Held over the band: the list without the dragged rows (the pin drop's outcome, cx-odqn).
        // A tile has no list row to move: the list opens its gap (`options`).
        guard let drag, drag.pinTarget == nil, drag.tileSource == nil, let position = shownPosition else {
            return SidebarLayout.make(sections: listSections, metrics: metrics, options: options(includeGap: true))
        }
        var sections = listSections
        switch drag.payload {
        // A group's index counts member rows. A group the drag empties keeps its header: it is still a drop target.
        case let .workspaces(ids): _ = SidebarEdits.reorder(ids, to: position, in: &sections, prunes: false)
        case .group: break // drawn by its plan, above
        case let .item(item): Self.move(item, to: position, in: &sections)
        }
        var o = options(includeGap: false)
        o.excludedWorkspaces = leaving
        o.excludedGroup = nil
        o.excludedItem = nil
        var layout = SidebarLayout.make(sections: sections, metrics: metrics, options: o)
        // The slot is where DropResolver maps display y back to base y
        // (the rows without the dragged ones).
        let slot = layout.rows.filter { drag.hiddenKeys.contains($0.key) }
        if let first = slot.first, let last = slot.last {
            layout.gapY = first.y
            layout.gapShift = last.maxY + metrics.rowSpacing - first.y
        }
        return layout
    }

    /// A listed document item at `position` (a loose slot, or a slot among a group's members, counted without it),
    /// as its drop would place it: from a loose row or from a group's members.
    static func move(_ item: String, to position: DropPosition, in sections: inout [SidebarSection]) {
        var moved: SidebarListItem?
        for s in sections.indices {
            if let n = sections[s].nodes.firstIndex(where: { $0.id == .item(item) }), case let .item(listed) = sections[s].nodes.remove(at: n) {
                moved = listed
            }
            for n in sections[s].nodes.indices {
                guard case var .group(group) = sections[s].nodes[n], let i = group.items.firstIndex(where: { $0.item.id == item }) else { continue }
                moved = group.items.remove(at: i).item
                sections[s].nodes[n] = .group(group)
            }
        }
        guard let moved, let s = sections.firstIndex(where: { $0.id == position.section }) else { return }
        guard let groupID = position.group else {
            sections[s].nodes.insert(.item(moved), at: min(max(0, position.index), sections[s].nodes.count))
            return
        }
        guard let n = sections[s].nodes.firstIndex(where: { $0.id == .group(groupID) }), case var .group(group) = sections[s].nodes[n] else { return }
        var members = group.members
        members.insert(.item(moved), at: min(max(0, position.index), members.count))
        group.setMembers(members)
        sections[s].nodes[n] = .group(group)
    }

    /// The dragged workspaces' tab rows hide with them (they move along).
    static func tabKeys(of hidden: Set<SidebarRowKey>, in model: SidebarModel) -> Set<SidebarRowKey> {
        var keys: Set<SidebarRowKey> = []
        for case let .workspace(id) in hidden {
            for tab in model.workspace(id)?.tabs ?? [] { keys.insert(.tab(id, tab.id)) }
        }
        return keys
    }
}
