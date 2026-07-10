import Bonsplit
import Foundation

extension Workspace {
    func terminalPortalPresentation(
        panelId: UUID,
        paneId: PaneID
    ) -> TerminalPortalPresentation {
        guard panels[panelId] != nil,
              let tabId = surfaceIdFromPanelId(panelId),
              bonsplitController.paneId(containing: tabId) == paneId else {
            return .detached
        }

        let manager = owningTabManager
        guard manager?.selectedTabId == id else {
            return .retained(zPriority: 1)
        }
        if let manager,
           let context = AppDelegate.shared?.mainWindowContext(for: manager),
           context.sidebarSelectionState.selection != .tabs {
            return .hidden
        }

        let paneIsRendered = bonsplitController.zoomedPaneId.map { $0.id == paneId.id } ?? true
        let panelIsSelected = bonsplitController.selectedTabId(inPane: paneId) == tabId
        let focusedPanelId = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTabId(inPane: $0) }
            .flatMap(panelIdFromSurfaceId)
        let panelIsRendered: Bool
        if layoutMode == .canvas {
            panelIsRendered = canvasModel.layout.panes.contains {
                $0.selectedPanelId.rawValue == panelId
            }
        } else {
            panelIsRendered = panelIsSelected || focusedPanelId == panelId
        }
        guard paneIsRendered, panelIsRendered else { return .hidden }

        let rightSidebarOwnsFocus = AppDelegate.shared?.rightSidebarOwnsInputFocus(for: self) ?? false
        return .visible(
            isActive: focusedPanelId == panelId && !rightSidebarOwnsFocus,
            zPriority: 2
        )
    }
}
