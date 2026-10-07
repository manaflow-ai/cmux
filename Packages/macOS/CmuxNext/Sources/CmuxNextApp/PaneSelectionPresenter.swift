/// Shows a pane's new selection so that no display frame mixes two tabs
/// (DOGFOOD-CALL L4). The strip's highlight and the content change in the
/// same pass, so they commit in one Core Animation transaction:
/// - content that is alive (a tab the user visited) is shown now;
/// - a first visit empties the pane now (its background, never the old
///   tab under the new highlight) and its surface is made on the next
///   frame within the one-new-surface budget, for whatever tab is
///   selected by then, so held Ctrl-Tab makes no surface for a tab it passed.
@MainActor
struct PaneSelectionPresenter {
    let pane: PaneController

    func present() {
        guard !pane.selectedContentIsAlive else {
            pane.services.presentation.showNow(pane)
            return
        }
        if let key = pane.currentTabKey {
            pane.services.cache.withdraw(key, by: pane)
            pane.surfaceWasDisplaced(key)
        }
        if pane.view.stripView.window != nil { pane.view.stripView.sync(fromModel: true) }
        pane.services.presentation.setNeedsShowSelected(pane)
    }
}
