import Bonsplit

@MainActor
extension RemoteTmuxWindowMirror {
    /// Whether nested focus moved, reached a valid boundary, or could not
    /// resolve authoritative pane ownership.
    enum FocusNavigationResult {
        /// Focus moved to a mapped pane inside the mirror.
        case moved
        /// The mapped focused pane has no neighbor in the requested direction.
        case edge
        /// Current or destination pane ownership could not be resolved.
        case invalid
    }

    /// Moves user focus inside this window's nested pane tree and establishes
    /// first responder on the destination surface. Remote active-pane events use
    /// ``focusBonsplitPane(forTmuxPane:)`` instead and therefore never steal key
    /// focus from the user.
    @discardableResult
    func navigateFocus(direction: NavigationDirection) -> FocusNavigationResult {
        guard let focusedPane = bonsplitController.focusedPaneId,
              let focusedTmuxPaneId = paneIdByBonsplitPane[focusedPane],
              panel(forPane: focusedTmuxPaneId) != nil else { return .invalid }
        guard let destinationPane = bonsplitController.adjacentPane(
            to: focusedPane,
            direction: direction
        ) else { return .edge }
        guard let tmuxPaneId = paneIdByBonsplitPane[destinationPane],
              let panel = panel(forPane: tmuxPaneId) else { return .invalid }

        bonsplitController.focusPane(destinationPane)
        guard bonsplitController.focusedPaneId == destinationPane else { return .invalid }
        if activePaneId != tmuxPaneId {
            setActivePane(tmuxPaneId, fromTmux: false)
        }
        panel.hostedView.moveFocus()
        return .moved
    }

    func seedActivePaneIfNeeded() {
        let live = renderedLayout.paneIDsInOrder
        let remoteActive = connection?.activePaneByWindow[windowId]
        let seed = remoteActive.flatMap { live.contains($0) ? $0 : nil } ?? live.first
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
