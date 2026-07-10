import Bonsplit
import Foundation

extension DockSplitStore {
    func terminalPortalPresentation(
        panelId: UUID,
        paneId: PaneID
    ) -> TerminalPortalPresentation {
        guard self.paneId(forPanelId: panelId)?.id == paneId.id else {
            return .detached
        }
        guard paneIsRenderedInVisibleDock(paneId),
              let selectedTab = bonsplitController.selectedTab(inPane: paneId),
              surfaceIdToPanelId[selectedTab.id] == panelId else {
            return .hidden
        }
        let ownsInputFocus = AppDelegate.shared?.rightSidebarOwnsInputFocus(for: self) ?? false
        return .visible(
            isActive: bonsplitController.focusedPaneId == paneId && ownsInputFocus,
            zPriority: 1
        )
    }
}
