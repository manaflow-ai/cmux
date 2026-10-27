import AppKit

// Chrome's tab multi-selection in the strip (`TabMultiSelection`): Cmd- and Shift-click, the
// lighter fill of the selected tabs, Esc, and a drag that takes every selected tab.
extension TabStripView {
    /// The selection a press with `modifiers` makes: Cmd toggles, Shift selects a range, both add one.
    static func selectionClick(_ modifiers: NSEvent.ModifierFlags) -> TabMultiSelection.Click {
        switch (modifiers.contains(.command), modifiers.contains(.shift)) {
        case (true, true): .addRange
        case (true, false): .toggle
        case (false, true): .range
        case (false, false): .plain
        }
    }

    /// A press on tab `id` (mouse down). A plain press on one of several selected tabs keeps them
    /// for a drag; its release selects that tab alone (`mouseUp`).
    func selectOnPress(_ id: TabID, modifiers: NSEvent.ModifierFlags) {
        let click = Self.selectionClick(modifiers)
        if click == .plain, model.multiSelection.isMultiple, model.multiSelection.contains(id) {
            press?.collapsesSelection = true
            if model.selectedID != id { model.send(.select(id)) }
            return
        }
        if let next = model.click(id, click), next != model.selectedID { model.send(.select(next)) }
    }

    /// Shows the model's multi-selection on the cells, and holds `selectionEscape` while there is one.
    func applyMultiSelection() {
        let selection = model.multiSelection
        for (id, cell) in cells { cell.isMultiSelected = selection.contains(id) }
        if selection.isMultiple { selectionEscape.install() } else { selectionEscape.remove() }
    }

    /// Hides the other selected tabs when `id`, one of several selected tabs, starts a drag.
    /// A strip with tab groups drags the one tab: the strip keeps a group's members together, so a
    /// multi-tab drop into or out of a group would ask for an order it can never show.
    func hideDragCompanions(of id: TabID) {
        guard model.multiSelection.isMultiple, model.multiSelection.contains(id), model.groups.isEmpty else { return }
        let companions = Set(model.selectedTabIDs).subtracting([id])
        guard !companions.isEmpty else { return }
        dragCompanions = companions
        sync(fromModel: false, animating: false)
    }

    /// The drop of a multi-tab drag: every selected tab moves to the dragged tab's place, in order,
    /// pinned and unpinned tabs each in their section (`TabSelectionMove`). Escape leaves them.
    func endMultiDrag(_ drag: TabStripDrag) {
        dragCompanions = []
        let current = model.orderedTabs.map(\.id)
        let order = model.orderMovingSelection(to: drag.currentIndex)
        guard !drag.cancelled, displayed.contains(where: { $0.id == drag.id }), order != current else {
            sync(fromModel: false)
            relayout(animated: !reduceMotion)
            return
        }
        orderOverride = order
        multiReorderTarget = order
        sync(fromModel: false)
        model.send(.reorderTabs(order))
        relayout(animated: !reduceMotion)
    }
}
