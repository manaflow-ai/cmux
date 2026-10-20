import AppKit
import CmuxNextDesign

/// A workspace or tab switch changes one fact, the selection, so the list
/// repaints the rows whose fill changed and nothing else
/// (plans/cmux-next/perf-speed-of-light.md I6): no `SidebarLayout.make`,
/// no row walk, no configure of the other rows.
extension SidebarListViewComponents {
    /// Draws a selection change from `oldItem` / `oldSelection` to the model's
    /// on the old and new rows only, then reveals the new active row as a
    /// reload would. False (nothing changed) when the change moves rows (a
    /// collapsed group draws its active member as its one visible row) or a
    /// drag holds the rows; the caller then reloads.
    func patchSelection(from oldItem: SidebarItem?, oldSelection: Set<WorkspaceID>) -> Bool {
        guard drag == nil, external == nil, settling == nil, landing == nil, !displayed.rows.isEmpty else { return false }
        let oldActive: WorkspaceID? = if case let .workspace(id)? = oldItem { id } else { nil }
        let newActive = model.activeWorkspaceID
        for id in [oldActive, newActive].compactMap({ $0 }) where model.isInCollapsedGroup(id) { return false }
        SidebarPerfCounters.add(.selectionPatches)
        let newKey: SidebarRowKey? = switch model.selectedItem {
        case let .workspace(id)?: displayed.row(for: .workspace(id)) == nil ? nil : .workspace(id)
        case let other: displayed.selectedRowKey(for: other, in: [])
        }
        let oldKey = selectedRowKey
        selectedRowKey = newKey
        if oldKey != newKey {
            if let oldKey { rowViews[oldKey]?.isSelected = false }
            if let newKey { rowViews[newKey]?.isSelected = true }
        }
        // The secondary fill: rows that joined or left the multi-selection, and the old and new primary rows.
        var touched = oldSelection.symmetricDifference(model.selection)
        for key in [oldKey, newKey] { if case let .workspace(id)? = key { touched.insert(id) } }
        for id in touched {
            guard let view = rowViews[.workspace(id)] as? WorkspaceRowView else { continue }
            view.isSecondarySelected = model.selection.contains(id) && !view.isSelected
        }
        if takeTopReveal() {
            revealedActive = newActive.map { SidebarRowKey.workspace($0) }
            scrollToTop()
        } else {
            revealPatchedActive(newActive.map { SidebarRowKey.workspace($0) })
        }
        return true
    }

    /// `applyKeepingViewport`'s reveal for a change that moved no row: a new
    /// active row that is not wholly in view scrolls in (with `Motion`).
    private func revealPatchedActive(_ active: SidebarRowKey?) {
        let previous = revealedActive
        revealedActive = active
        guard let clip = enclosingScrollView?.contentView, case let height = clip.bounds.height, height > 0 else {
            // No viewport yet: the first reload with one reveals (as `applyKeepingViewport`).
            revealedActive = nil
            return
        }
        guard let active, active != previous, let row = displayed.row(for: active) else { return }
        let item = ListViewport<SidebarRowKey>.Item(id: active, start: row.y, length: row.height)
        let viewport = ListViewport(items: [item], viewport: height, content: max(displayed.totalHeight, height))
        let offset = clip.bounds.minY
        guard !viewport.isFullyVisible(item, at: offset, padding: 0) else { return }
        let target = viewport.reveal(item, from: offset, padding: SidebarLayout.revealPadding)
        if abs(target - offset) > 0.25 { scrollClip(to: target, animated: true) }
    }
}
