import Bonsplit
import Foundation

extension DockSplitStore {
    func terminalPortalPresentation(
        panelId: UUID,
        tabId: TabID,
        paneId: PaneID
    ) -> TerminalPortalPresentation {
        guard panels[panelId] != nil,
              surfaceIdToPanelId[tabId] == panelId,
              bonsplitController.paneId(containing: tabId) == paneId else {
            return .detached
        }
        guard paneIsRenderedInVisibleDock(paneId),
              bonsplitController.selectedTabId(inPane: paneId) == tabId else {
            return .hidden
        }
        let rightSidebarOwnsInputFocus = AppDelegate.shared?.rightSidebarOwnsInputFocus(for: self) ?? false
        return .visible(
            isActive: bonsplitController.focusedPaneId == paneId && !rightSidebarOwnsInputFocus,
            zPriority: 1
        )
    }
}
