import AppKit

/// A keyboard or click selection of a top item (Home, the App Store) or of the
/// first workspace scrolls the list to its very top, so the pinned items above
/// the rows show (`SidebarItemOrder.revealsTop`). The reveal of any other row
/// stays with `applyKeepingViewport` / `patchSelection`.
extension SidebarListViewComponents {
    /// Takes the model's selection for this reload or patch: true when it changed to
    /// an item that `revealsTop` (once per change). Every reload takes it, so a change
    /// a drag held back never scrolls a later one. Without a viewport it takes nothing:
    /// the first reload with one reveals (as `revealedActive`).
    func takeTopReveal() -> Bool {
        guard (enclosingScrollView?.contentView.bounds.height ?? 0) > 0 else {
            revealedSelection = nil
            return false
        }
        let selected = model.selectedItem
        let previous = revealedSelection
        revealedSelection = selected
        return selected != previous && model.itemOrder.revealsTop(for: selected)
    }

    /// Scrolls the list to offset 0 (with `Motion`).
    func scrollToTop() {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.minY > 0.25 else { return }
        scrollClip(to: 0, animated: true)
    }
}
