import CmuxPanes
import CmuxSettings
import Foundation

extension DockSplitStore {
    func equalizeDockSplits() -> Bool {
        let result = PaneLayoutService().equalizeSplits(
            in: bonsplitController.treeSnapshot(),
            controller: bonsplitController
        )
        return result.foundSplit && result.allSucceeded
    }

    func resizeFocusedPane(direction: ResizeDirection) -> Bool {
            guard let pane = bonsplitController.focusedPaneId,
                  let focusedTab = bonsplitController.selectedTab(inPane: pane),
                  let panelId = surfaceIdToPanelId[focusedTab.id],
                  let paneId = paneId(forPanelId: panelId) else {
                return false
            }
            let didResize = PaneLayoutService().resizeSplit(
                in: bonsplitController.treeSnapshot(),
                targetPaneId: paneId.id.uuidString,
                direction: direction,
                amountPixels: PaneResizeStepSettings(defaults: .standard).currentPixels(),
                controller: bonsplitController
            )
            return didResize
    }
}
