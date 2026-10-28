/// Shows a pane's new selection so that no display frame mixes two tabs
/// (DOGFOOD-CALL L4). The strip's highlight and the content change in the
/// same pass, so they commit in one Core Animation transaction:
/// - content that is alive (a tab the user visited) is shown now;
/// - a first visit empties the pane now (its background, never the old
///   tab under the new highlight) and its surface is made on the next
///   frame within the one-new-surface budget, for whatever tab is
///   selected by then, so held Ctrl-Tab makes no surface for a tab it passed.
extension PaneController {
    func presentSelection() {
        guard !isSuspended else { return } // its workspace draws nothing: `resume` shows the selection
        guard !selectedContentIsAlive else {
            services.presentation.showNow(self)
            return
        }
        DebugTabSwitch.kind(self, "cold")
        if let key = currentTabKey {
            services.cache.withdraw(key, by: self)
            letGo(key, parks: true) // what showed stays parked here
        }
        if view.stripView.window != nil { view.stripView.syncFromModel() }
        if isFocusedInWorkspace, showsLiveTerminal {  // keys typed meanwhile wait for its surface
            services.keyRouter.creationInputCoordinator.holdUntilShown(in: view.window)
        }
        services.presentation.setNeedsShowSelected(self)
    }
}
