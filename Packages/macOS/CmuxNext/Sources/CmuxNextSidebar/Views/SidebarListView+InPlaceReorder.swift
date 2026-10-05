import CoreGraphics

// R77: a drag reorders in place. While the pointer is over a slot, the
// displayed layout already holds the dragged rows there (hidden under the
// lifted view) and the other rows spring out of the way; there is no
// placeholder underlay. On release the model takes the same order, so the
// lifted view settles into a slot that does not move.
extension SidebarListView {
    /// The layout the list shows: the model's, or during an internal drag
    /// over a slot, the model with the dragged rows moved to that slot.
    func displayLayout() -> SidebarLayout {
        guard let drag, case let .position(position)? = drag.target else {
            return SidebarLayout.make(sections: model.sections, metrics: metrics, options: options(includeGap: true))
        }
        var sections = model.sections
        switch drag.payload {
        case let .workspaces(ids): SidebarEdits.apply(.reorder(ids, to: position), to: &sections)
        case let .group(group): SidebarEdits.apply(.reorderGroup(group, index: position.index), to: &sections)
        }
        var o = options(includeGap: false)
        o.excludedWorkspaces = []
        o.excludedGroup = nil
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

    /// The dragged workspaces' tab rows hide with them (they move along).
    static func tabKeys(of hidden: Set<SidebarRowKey>, in model: SidebarModel) -> Set<SidebarRowKey> {
        var keys: Set<SidebarRowKey> = []
        for case let .workspace(id) in hidden {
            for tab in model.workspace(id)?.tabs ?? [] { keys.insert(.tab(id, tab.id)) }
        }
        return keys
    }
}
