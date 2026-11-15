import Foundation

/// Live preview for list pages (`PalettePageSpec.onHighlight`/`onLeave`):
/// the page hears which row is highlighted (the hovered row, else the
/// selected one; the selected one after a key moved it, until the pointer
/// moves) and when it is left without choosing.
extension PaletteModel {
    func reportHighlight() {
        guard let state = current, case .list(let page) = state.kind, let onHighlight = page.onHighlight else { return }
        let id = keyboardLeads ? selectedRowID : hoveredRowID ?? selectedRowID
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
    ///
    /// A hidden page reads nothing more: a read that still runs ends here, and a read left for after
    /// the frame does not start. A list that is not complete would else be read again each few seconds
    /// behind the hidden palette (`AsyncPaletteProvider.rereading`). Such a page loads again when it
    /// shows again (``didShowAgain()``, or a pop to it).
    public func didHide() {
        for load in deferredLoads { load.state.needsLoad = true }
        deferredLoads = []
        for state in stack.reversed() {
            if state.liveReads > 0 {
                state.cancelReads()
                state.needsLoad = true
                // The reads that ended give no rows: the page waits for none, until it loads again.
                state.pendingProviders = []
                if state === current { isLoading = state.answersQuery }
            }
            leave(state)
        }
    }

    /// The palette shows again on the page it hid on (a refused command's notice): a page whose
    /// reads the hide ended reads again. Its rows stay until the new ones come.
    public func didShowAgain() {
        if current?.needsLoad == true { reload() }
    }

    func leave(_ state: PageState) {
        let wasHighlighted = state.highlightedItemID != nil
        state.highlightedItemID = nil
        // A left page asks its sources nothing more.
        state.sourceTokens = []
        guard case .list(let page) = state.kind else { return }
        // A contributed page's queries hold its source (acpmux's window) open however the page is left.
        if !page.contributedAnswers.isEmpty {
            state.cancelAnswers()
            state.answeredQuery = nil
            for contribution in page.contributedAnswers { contribution.close?() }
        }
        guard page.onLeave != nil || page.onCancel != nil else { return }
        if state.committed {
            state.committed = false
            return
        }
        if wasHighlighted { page.onLeave?() }
        page.onCancel?()
    }
}
