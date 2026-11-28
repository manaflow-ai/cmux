import Foundation

/// Live preview for list pages (`PalettePageSpec.onHighlight`/`onLeave`):
/// the page hears which row is highlighted (the hovered row, else the
/// selected one) and when it is left without choosing.
extension PaletteModel {
    func reportHighlight() {
        guard let state = current, case .list(let page) = state.kind, let onHighlight = page.onHighlight else { return }
        let id = hoveredRowID ?? selectedRowID
        guard id != state.highlightedItemID else { return }
        state.highlightedItemID = id
        // The row selected as the page opens previews nothing (a theme
        // picker must not flash its first theme); moving previews.
        guard state.hasInitialHighlight else {
            state.hasInitialHighlight = id != nil
            return
        }
        let item = id.flatMap { id in rows.first { $0.id == id }?.item }
        onHighlight(item)
    }

    /// The palette closed. Pages that ran no closing command revert their
    /// preview; a later reopen on the same page previews again.
    public func didHide() {
        for state in stack.reversed() { leave(state) }
    }

    func leave(_ state: PageState) {
        let wasHighlighted = state.highlightedItemID != nil
        state.highlightedItemID = nil
        guard case .list(let page) = state.kind, page.onLeave != nil || page.onCancel != nil else { return }
        if state.committed {
            state.committed = false
            return
        }
        if wasHighlighted { page.onLeave?() }
        page.onCancel?()
    }
}
