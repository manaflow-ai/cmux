/// Which tab separators the strip draws (TAB-STRIP-TRAILING-BUTTONS-REMOVED
/// amendment 2, Chrome's rule). Separator `i` is the line in the gap after
/// tab `i`; the last one sits between the last tab and the + button.
struct TabSeparatorVisibility {
    /// The separators that show in a row of `tabCount` tabs. A separator
    /// shows only when neither neighbor is selected, hovered or dragged, so
    /// each of those tabs hides the separators on both of its sides. The
    /// separator before + has one neighbor tab, the last one. Indices
    /// outside the row are ignored. `multiSelected`: the other tabs of a multi-selection, which
    /// draw a fill too.
    static func visibleSeparators(tabCount: Int, selected: Int?, hovered: Int?, dragged: Int?, multiSelected: Set<Int> = []) -> Set<Int> {
        guard tabCount > 0 else { return [] }
        let emphasized = Set([selected, hovered, dragged].compactMap(\.self)).union(multiSelected)
        var visible: Set<Int> = []
        for index in 0..<tabCount where !emphasized.contains(index) && !emphasized.contains(index + 1) {
            visible.insert(index)
        }
        return visible
    }

    /// The same rule for the lines a change of `ids`' emphasis can flip (each tab's own line and the
    /// one before it), so a tab switch costs O(1) at any tab count. The other lines keep what the
    /// last full ``apply(to:)`` gave them: nothing else they depend on changed.
    @MainActor static func apply(to strip: TabStripView, around ids: [TabID?]) {
        let index = strip.slotIndex
        let row = index.row
        func at(_ id: TabID?) -> Int? { id.flatMap { index.rowIndex[$0] } }
        var emphasized = Set([at(strip.model.selectedID), at(strip.hoveredID),
                              at(strip.drag?.id) ?? at(TabStripView.placeholderID)].compactMap(\.self))
        for id in strip.model.multiSelection.ids { if let i = at(id) { emphasized.insert(i) } }
        var lines = Set<Int>()
        for id in ids { if let i = at(id) { lines.formUnion([i - 1, i]) } }
        for line in lines where line >= 0 && line < row.count {
            let shows = strip.metrics.showsSeparators && !emphasized.contains(line) && !emphasized.contains(line + 1)
            strip.cells[row[line]]?.showsSeparator = shows
        }
    }

    /// Chrome's rule over the strip's row: the selected, hovered and dragged tabs hide the lines on
    /// both sides, and the last tab's line is the one before +. A drop gap counts as the dragged
    /// tab. Members collapsed into a group chip are out of the row and draw none; a chip is a
    /// neutral neighbor. None while `tabs.separators` is off.
    @MainActor static func apply(to strip: TabStripView) {
        strip.rowPasses.separators &+= 1
        let row = strip.result.slots.filter { !$0.isCollapsed }
        // Each tab's first place in the row, built once: a lookup per selected tab, not a scan (O(n), not O(n·m)).
        var places: [TabID: Int] = [:]
        places.reserveCapacity(row.count)
        for (offset, slot) in row.enumerated() where places[slot.id] == nil { places[slot.id] = offset }
        func index(of id: TabID?) -> Int? { id.flatMap { places[$0] } }
        let visible = visibleSeparators(
            tabCount: row.count,
            selected: index(of: strip.model.selectedID),
            hovered: index(of: strip.hoveredID),
            dragged: index(of: strip.drag?.id) ?? index(of: TabStripView.placeholderID),
            multiSelected: Set(strip.model.multiSelection.ids.compactMap { index(of: $0) })
        )
        let shown = strip.metrics.showsSeparators ? Set(visible.map { row[$0].id }) : []
        for slot in strip.result.slots {
            strip.cells[slot.id]?.showsSeparator = shown.contains(slot.id)
        }
    }
}
