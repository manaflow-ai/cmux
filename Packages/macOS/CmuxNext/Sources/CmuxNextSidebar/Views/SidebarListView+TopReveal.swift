import AppKit

/// A keyboard or click selection of a top item (Home, the App Store) or of the
/// first row scrolls the list to its very top, so the pinned items above the
/// rows show (`SidebarItemOrder.revealsTop`). The reveal of any other row stays
/// with `applyKeepingViewport` / `patchSelection`.
extension SidebarListViewComponents {
    /// Scrolls to offset 0 when the selection changed to an item that
    /// `revealsTop`; true when this change is such a selection (the caller
    /// then makes no other reveal).
    @discardableResult
    func revealTopForSelection() -> Bool {
        let selected = model.selectedItem
        let previous = revealedSelection
        revealedSelection = selected
        guard selected != previous, model.itemOrder.revealsTop(for: selected) else { return false }
        guard let clip = enclosingScrollView?.contentView, clip.bounds.height > 0 else { return true }
        if clip.bounds.minY > 0.25 { scrollClip(to: 0, animated: true) }
        return true
    }
}
