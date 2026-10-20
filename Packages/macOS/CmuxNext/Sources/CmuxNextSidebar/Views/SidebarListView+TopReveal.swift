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
    ///
    /// - Parameter layout: the rows as they draw after this change (the reload's new
    ///   layout; a patch keeps `displayed`). A workspace with a row reveals the top when
    ///   no stop but top items draws before it, which `layout` tells from its first rows,
    ///   so a space switch never builds the whole item order of the new space.
    func takeTopReveal(in layout: SidebarLayout? = nil) -> Bool {
        guard (enclosingScrollView?.contentView.bounds.height ?? 0) > 0 else {
            revealedSelection = nil
            return false
        }
        let selected = model.selectedItem
        let previous = revealedSelection
        revealedSelection = selected
        guard selected != previous else { return false }
        if case let .workspace(id)? = selected, let first = isFirstStop(id, in: layout ?? displayed) { return first }
        return model.itemOrder.revealsTop(for: selected)
    }

    /// ``SidebarItemOrder/revealsTop(for:)`` for workspace `id` read from the drawn rows:
    /// false when a selectable workspace or a collapsed group (a stop) draws before its
    /// row, true when its row comes first. Nil when `layout` draws no row for it (in a
    /// collapsed group, filtered out): the caller asks the item order.
    private func isFirstStop(_ id: WorkspaceID, in layout: SidebarLayout) -> Bool? {
        let selectable = { (workspace: WorkspaceID) in self.model.workspace(workspace)?.rowState.isPending == false }
        for row in layout.rows {
            switch row.key {
            case let .workspace(other) where other == id:
                return selectable(id)
            case let .workspace(other) where selectable(other):
                return false
            case let .group(group):
                if let group = model.group(group), group.isCollapsed, group.workspaces.contains(where: { selectable($0.id) }) { return false }
            default:
                continue
            }
        }
        return nil
    }

    /// Scrolls the list to offset 0 (with `Motion`).
    func scrollToTop() {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.minY > 0.25 else { return }
        scrollClip(to: 0, animated: true)
    }
}
