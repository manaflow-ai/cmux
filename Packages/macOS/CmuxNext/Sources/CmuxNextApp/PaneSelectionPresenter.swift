import CmuxNextCompat
/// Shows a pane's new selection in one Core Animation transaction with the strip's highlight (DOGFOOD-CALL L4), never
/// an empty pane between two tabs (Leo 2026-11-22, "when i click on an unloaded tab of anything at all the whole pane
/// re-renders"; "when i move one tab completely to another pane, the original pane flickers a re-render"):
/// - content that is alive (a tab the user visited) is shown now;
/// - a first visit keeps the old tab drawn until `showSelected` swaps the new one in; its surface is made next frame
///   within the one-new-surface budget, for whatever tab is selected by then (held Ctrl-Tab makes none for a tab it
///   passed). A pane a tab move left empty (`leftEmptyByMove`) shows it now, within the budget.
extension PaneController {
    func presentSelection() {
        guard !isSuspended else { return } // its workspace draws nothing: `resume` shows the selection
        guard !selectedContentIsAlive else { services.presentation.showNow(self); return }
        DebugTabSwitch.kind(self, "cold")
        if currentTabKey != nil { view.contentHost.handKeyboardToWindow() } // keys go to the new tab; the old stays drawn
        if view.stripView.window != nil { view.stripView.syncFromModel() }
        if isFocusedInWorkspace, showsLiveTerminal { services.keyRouter.creationInputCoordinator.holdUntilShown(in: view.window) } // keys wait for its surface
        if leftEmptyByMove, !view.hostsContent { leftEmptyByMove = false; services.presentation.showNow(self) } else { services.presentation.setNeedsShowSelected(self) }
    }

    /// A move took `key`'s view after this pane selected another tab: it shows before the commit (not inline: the cache is mid-change).
    func showSelectionAfterDisplacement(of key: String) {
        guard !isSuspended, let selected = stripModel.selectedID?.rawValue, selected != key, currentTabKey == nil else { return }
        MainRunLoopBlock.perform { [weak self] in
            guard let self, !self.isSuspended, self.currentTabKey == nil, self.stripModel.selectedID?.rawValue == selected else { return }
            self.leftEmptyByMove = false; self.services.presentation.showNow(self)
        }
    }
}
