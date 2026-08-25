import Bonsplit
import Foundation

extension DockSplitStore {
    /// Moves the focused Dock pane to a new edge split while retaining all of
    /// its live terminal/browser surfaces.
    @discardableResult
    func moveFocusedPane(to movement: PaneOuterSplitMovement) -> Bool {
        ensureLoaded()
        guard let sourcePaneId = bonsplitController.focusedPaneId else {
            return false
        }

        let sourceTabs = bonsplitController.tabs(inPane: sourcePaneId)
        guard !sourceTabs.isEmpty else { return false }
        let selectedTabId = bonsplitController.selectedTab(inPane: sourcePaneId)?.id
        let selectedPanelId = selectedTabId.flatMap { surfaceIdToPanelId[$0] }

        let didMove = PaneOuterSplitLayoutMutation.movePane(
            sourcePaneId,
            in: bonsplitController,
            movement: movement
        ) { [weak self] pane, orientation, tab, insertFirst in
            guard let self else { return nil }
            return self.withProgrammaticDockSplit {
                self.bonsplitController.splitPane(
                    pane,
                    orientation: orientation,
                    withTab: tab,
                    insertFirst: insertFirst
                )
            }
        }

        guard didMove else { return false }
        synchronizeOwnedPaneIds(with: bonsplitController)
        scheduleDockPortalReconcile(reason: "dock.movePaneToNewOuterSplit")

        if let selectedPanelId, panels[selectedPanelId] != nil {
            focusPanelFromDockInteraction(selectedPanelId, window: nil)
        } else if let focusedPanelId, panels[focusedPanelId] != nil {
            focusPanelFromDockInteraction(focusedPanelId, window: nil)
        } else {
            bonsplitController.focusPane(sourcePaneId)
        }
        return true
    }
}
