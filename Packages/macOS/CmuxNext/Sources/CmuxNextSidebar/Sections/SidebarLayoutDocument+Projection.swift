extension SidebarLayoutDocument {
    /// Convert an insertion slot in the visible layout to the saved layout.
    /// Moves exclude their own item; drop-to-pin insertions exclude nothing.
    /// Hidden rows stay saved while the insertion follows a visible neighbour
    /// (Rust `sidebar_layout_plan::stored_insertion_index`).
    public func storedInsertionIndex(_ index: Int, in sectionID: LayoutSectionID,
                                     from projected: SidebarLayoutDocument, excluding id: LayoutItemID? = nil) -> Int {
        var request = SidebarLayoutPlanRequest("stored_index")
        request.stored = self
        request.projected = projected
        request.section = sectionID
        request.index = index
        request.excluding = id
        return SidebarLayoutReducer.plan(request)?.index ?? index
    }
}
