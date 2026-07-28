import Bonsplit

@MainActor
extension RemoteTmuxWindowMirror {
    /// Moves user focus inside this window's nested pane tree and establishes
    /// first responder on the destination surface. Remote active-pane events use
    /// ``focusBonsplitPane(forTmuxPane:)`` instead and therefore never steal key
    /// focus from the user.
    @discardableResult
    func navigateFocus(direction: NavigationDirection) -> Bool {
        let previousPane = bonsplitController.focusedPaneId
        bonsplitController.navigateFocus(direction: direction)
        guard let focusedPane = bonsplitController.focusedPaneId,
              focusedPane != previousPane,
              let tmuxPaneId = paneIdByBonsplitPane[focusedPane],
              let panel = panel(forPane: tmuxPaneId) else { return false }

        if activePaneId != tmuxPaneId {
            setActivePane(tmuxPaneId, fromTmux: false)
        }
        panel.hostedView.moveFocus()
        return true
    }

    func seedActivePaneIfNeeded() {
        let live = renderedLayout.paneIDsInOrder
        let seed = connection?.activePaneByWindow[windowId] ?? live.first
        if activePaneId.map({ live.contains($0) }) != true, let seed {
            setActivePane(seed, fromTmux: true)
        } else if let activePaneId {
            setActivePane(activePaneId, fromTmux: true)
        }
    }

    func isFocused(tabId: TabID) -> Bool {
        tmuxPaneId(forTab: tabId).map { $0 == activePaneId } ?? false
    }

    func focusBonsplitPane(forTmuxPane paneId: Int) {
        // Reconciles reassert the active pane on every layout echo. Skip an
        // unchanged focus so remote truth cannot disturb the first responder.
        guard let bonsplitPane = paneIdByPaneId[paneId],
              bonsplitController.focusedPaneId != bonsplitPane else { return }
        isApplyingTmuxFocus = true
        bonsplitController.focusPane(bonsplitPane)
        isApplyingTmuxFocus = false
    }
}
