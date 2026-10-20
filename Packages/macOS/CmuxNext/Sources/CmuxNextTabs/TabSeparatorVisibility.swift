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

    /// Chrome's rule over the strip's row: the selected, hovered and dragged tabs hide the lines on
    /// both sides, and the last tab's line is the one before +. A drop gap counts as the dragged
    /// tab. Members collapsed into a group chip are out of the row and draw none; a chip is a
    /// neutral neighbor. None while `tabs.separators` is off.
    @MainActor static func apply(to strip: TabStripView) {
        let row = strip.result.slots.filter { !$0.isCollapsed }
        func index(of id: TabID?) -> Int? { id.flatMap { id in row.firstIndex { $0.id == id } } }
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
