import AppKit
import CmuxNextDesign

/// A workspace or tab switch changes one fact, the selection, so the list
/// repaints the rows whose fill changed and nothing else
/// (plans/cmux-next/perf-speed-of-light.md I6): no `SidebarLayout.make`,
/// no row walk, no configure of the other rows.
extension SidebarListViewComponents {
    /// Whether the list draws the selected workspace's row already (a clicked row always is).
    var showsSelectionRow: Bool { model.activeWorkspaceID.map { displayed.row(for: .workspace($0)) != nil } ?? false }

    /// Draws a selection change from `oldItem` / `oldSelection` to the model's
    /// on the old and new rows only, then reveals the new active row as a
    /// reload would. False (nothing changed) when the change moves rows (a
    /// collapsed group or a "Done (N)" row draws a member it did not draw before) or a
    /// drag holds the rows; the caller then reloads. The old active row stays where it is even when only being active
    /// kept it out of "Done (N)" or "Show N more": a click moves no row, and the next reload folds it.
    func patchSelection(from oldItem: SidebarItem?, oldSelection: Set<WorkspaceID>) -> Bool {
        guard drag == nil, external == nil, settling == nil, landing == nil, !displayed.rows.isEmpty else { return false }
        let oldActive: WorkspaceID? = if case let .workspace(id)? = oldItem { id } else { nil }
        let newActive = model.activeWorkspaceID
        // A collapsed group's member the list does not draw yet joins the rows; one it draws stays (`revealedMembers`).
        for id in [oldActive, newActive].compactMap({ $0 }) where model.isInCollapsedGroup(id) && displayed.row(for: .workspace(id)) == nil {
            return false
        }
        // A listed workspace the list does not draw (behind a "Done (N)" row) shows in its place once active.
        if let newActive, model.filterText.isEmpty, displayed.row(for: .workspace(newActive)) == nil, model.lists(newActive) { return false }
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
            paintSecondaryFills(view, id)
        }
        revealPatchedSelection()
        return true
    }

    /// `applyKeepingViewport`'s reveal for a change that moved no row: a new
    /// selection whose reveal (`selectionReveal`: its row with the header and
    /// list top around it, or its item in a block) is not wholly in view
    /// scrolls in (with `Motion`).
    private func revealPatchedSelection() {
        let active = selectionRevealKey
        let previous = revealedActive
        revealedActive = active
        guard (enclosingScrollView?.contentView.bounds.height ?? 0) > 0 else {
            // No viewport yet: the first reload with one reveals (as `applyKeepingViewport`).
            revealedActive = nil
            return
        }
        guard let active, active != previous else { return }
        revealSelectionNow()
    }

    /// Scrolls the selection's reveal (`selectionReveal`) into view now when
    /// it is not wholly in view, whether or not the selection changed: the
    /// one reveal a selection change uses, and Cmd-`n` pressed again on the
    /// item it already selected (`SidebarView.revealSelection`).
    func revealSelectionNow() {
        guard drag == nil, let clip = enclosingScrollView?.contentView, case let height = clip.bounds.height, height > 0,
              let item = selectionReveal(in: displayed, height: height) else { return }
        let viewport = ListViewport(items: [item], viewport: height, content: max(displayed.totalHeight, height))
        let offset = clip.bounds.minY
        guard !viewport.isFullyVisible(item, at: offset, padding: 0) else { return }
        let target = viewport.reveal(item, from: offset, padding: SidebarLayout.revealPadding)
        if abs(target - offset) > 0.25 { scrollClip(to: target, animated: true) }
    }
}
