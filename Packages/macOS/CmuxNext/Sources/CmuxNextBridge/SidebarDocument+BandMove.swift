public import CmuxNextSidebar

extension SidebarDocument {
    /// Moves sidebar workspace `id`'s item of a band section (a tile or top row of Pinned, which has no row in the
    /// workspace list) to where `placement` puts it among that section's items, as one move of the document.
    ///
    /// - Parameters:
    ///   - id: The moving workspace's sidebar id.
    ///   - placement: Where it goes, given a lookup from a sidebar workspace id to its document item (for Move
    ///     Above/Below's anchor). Nil refuses the move.
    /// - Returns: Nil while the document is not shown or does not place `id` (the layout document decides then);
    ///   false when no band section lists it, or the anchor is not in its section; true when it moved or already
    ///   was there.
    public func moveBand(workspace id: String, _ placement: ((String) -> String?) -> SidebarBandPlacement?) -> Bool? {
        guard let store = activeStore, let layout = store.shown?.layout, let moving = item(workspace: id) else { return nil }
        guard let to = placement({ self.item(workspace: $0) }), let move = layout.bandMove(moving, to) else { return false }
        if case let .move(_, _, target) = move { store.move([moving], to: target, title: SidebarDocStore.moveTitle) }
        return true
    }
}
