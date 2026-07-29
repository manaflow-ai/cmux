import Bonsplit

@MainActor
extension RemoteTmuxWindowMirror {
    enum FocusNavigationResult {
        case moved
        case edge
        case invalid
    }

    /// Moves keyboard focus inside the mirror's nested pane tree.
    ///
    /// Remote active-pane publications use ``focusBonsplitPane(forTmuxPane:)``
    /// instead, so a co-attached client can update the indicator without
    /// stealing this client's first responder.
    @discardableResult
    func navigateFocus(direction: NavigationDirection) -> FocusNavigationResult {
        guard let focusedPane = bonsplitController.focusedPaneId,
              let focusedTmuxPaneId = paneIdByBonsplitPane[focusedPane],
              panel(forPane: focusedTmuxPaneId) != nil else {
            return .invalid
        }
        guard let destinationPane = bonsplitController.adjacentPane(
            to: focusedPane,
            direction: direction
        ) else {
            return .edge
        }
        guard let tmuxPaneId = paneIdByBonsplitPane[destinationPane],
              let panel = panel(forPane: tmuxPaneId) else {
            return .invalid
        }

        bonsplitController.focusPane(destinationPane)
        guard bonsplitController.focusedPaneId == destinationPane else {
            return .invalid
        }
        if activePaneId != tmuxPaneId {
            setActivePane(tmuxPaneId, fromTmux: false)
        }
        panel.hostedView.moveFocus()
        return .moved
    }
}
