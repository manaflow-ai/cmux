import Bonsplit
import Foundation

@MainActor
extension RemoteHerdrWindowMirrorHost {
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
    /// ``focusBonsplitPane(forHerdrPane:)`` instead and therefore never steal key
    /// focus from the user.
    @discardableResult
    func navigateFocus(direction: NavigationDirection) -> FocusNavigationResult {
        guard let focusedPane = bonsplitController.focusedPaneId,
              let focusedHerdrPaneId = paneIdByBonsplitPane[focusedPane],
              panel(forPane: focusedHerdrPaneId) != nil else { return .invalid }
        guard let destinationPane = bonsplitController.adjacentPane(
            to: focusedPane,
            direction: direction
        ) else { return .edge }
        guard let herdrPaneId = paneIdByBonsplitPane[destinationPane],
              let panel = panel(forPane: herdrPaneId) else { return .invalid }

        bonsplitController.focusPane(destinationPane)
        guard bonsplitController.focusedPaneId == destinationPane else { return .invalid }
        if activePaneID != herdrPaneId {
            setActivePane(herdrPaneId, fromProvider: false)
        }
        panel.hostedView.moveFocus()
        return .moved
    }

    /// Layout-tree neighbor via package ``RemoteHerdrControl.adjacentPane``.
    func adjacentHerdrPane(direction: String) -> String? {
        guard let layout = renderedLayout, let activePaneID else { return nil }
        return RemoteHerdrControl.adjacentPane(layout, paneID: activePaneID, direction: direction)
    }

    func seedActivePaneIfNeeded() {
        let live = renderedLayout?.paneIDsInOrder ?? panelsByPaneId.keys.sorted()
        if let activePaneID, live.contains(activePaneID) {
            projectActivePane(activePaneID)
        } else if let seed = live.first {
            projectActivePane(seed)
        }
    }

    func focusBonsplitPane(forHerdrPane paneId: String) {
        // Reconciles reassert the active pane on every layout echo. Skip an
        // unchanged focus so remote truth cannot disturb the first responder.
        guard let bonsplitPane = paneIdByPaneId[paneId],
              bonsplitController.focusedPaneId != bonsplitPane else { return }
        isApplyingFocus = true
        bonsplitController.focusPane(bonsplitPane)
        isApplyingFocus = false
    }
}
