extension SidebarLayoutDocument {
    /// Convert an insertion slot in the visible layout to the saved layout.
    /// Moves exclude their own item; drop-to-pin insertions exclude nothing.
    /// Hidden rows stay saved while the insertion follows a visible neighbour.
    public func storedInsertionIndex(_ index: Int, in sectionID: LayoutSectionID,
                                     from projected: SidebarLayoutDocument, excluding id: LayoutItemID? = nil) -> Int {
        guard let visible = projected.section(sectionID), let full = section(sectionID) else { return index }
        let visibleRest = visible.items.filter { $0.id != id }
        let fullRest = full.items.filter { $0.id != id }
        guard visibleRest.count != fullRest.count else { return index }
        if visibleRest.indices.contains(index),
           let position = fullRest.firstIndex(where: { $0.id == visibleRest[index].id }) {
            return position
        }
        if let last = visibleRest.last, let position = fullRest.firstIndex(where: { $0.id == last.id }) {
            return position + 1
        }
        return fullRest.count
    }
}
