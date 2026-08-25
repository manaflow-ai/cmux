import Bonsplit
import Foundation

extension Workspace {
    /// Moves the focused pane, with all of its live surfaces, to a new split
    /// around the workspace root.
    @discardableResult
    func moveFocusedPane(to movement: PaneOuterSplitMovement) -> Bool {
        guard layoutMode != .canvas,
              !isRemoteTmuxMirror,
              let sourcePaneId = bonsplitController.focusedPaneId else {
            return false
        }

        let sourceTabs = bonsplitController.tabs(inPane: sourcePaneId)
        guard !sourceTabs.isEmpty else { return false }
        let selectedTabId = bonsplitController.selectedTab(inPane: sourcePaneId)?.id
        let sourcePanelIds = sourceTabs.compactMap { panelIdFromSurfaceId($0.id) }

        let didMove = PaneOuterSplitLayoutMutation.movePane(
            sourcePaneId,
            in: bonsplitController,
            movement: movement
        ) { [weak self] pane, orientation, tab, insertFirst in
            guard let self else { return nil }
            let previousProgrammaticState = self.isProgrammaticSplit
            self.isProgrammaticSplit = true
            defer { self.isProgrammaticSplit = previousProgrammaticState }
            return self.bonsplitController.splitPane(
                pane,
                orientation: orientation,
                withTab: tab,
                insertFirst: insertFirst
            )
        }

        guard didMove else { return false }

        for panelId in sourcePanelIds {
            scheduleMovedTerminalRefresh(panelId: panelId)
        }
        scheduleTerminalGeometryReconcile()

        if let selectedTabId,
           let selectedPanelId = panelIdFromSurfaceId(selectedTabId),
           panels[selectedPanelId] != nil {
            focusPanel(selectedPanelId)
        } else if let focusedPanelId,
                  panels[focusedPanelId] != nil {
            focusPanel(focusedPanelId)
        } else {
            bonsplitController.focusPane(sourcePaneId)
        }
        return true
    }
}
