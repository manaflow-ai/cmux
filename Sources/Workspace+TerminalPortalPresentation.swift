import Bonsplit
import Foundation

#if DEBUG
@MainActor
enum TerminalPortalPresentationDebugCounters {
    static var workspaceCandidateTabProbes = 0
    static var dockCandidateTabProbes = 0
}
#endif

extension Workspace {
    func terminalPortalPresentation(
        panelId: UUID,
        paneId: PaneID
    ) -> TerminalPortalPresentation {
        guard panels[panelId] != nil else { return .detached }
        let panelBelongsToCandidatePane = bonsplitController.tabs(inPane: paneId).contains { tab in
#if DEBUG
            TerminalPortalPresentationDebugCounters.workspaceCandidateTabProbes += 1
#endif
            return panelIdFromSurfaceId(tab.id) == panelId
        }
        guard panelBelongsToCandidatePane else {
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
        let panelIsRendered: Bool
        if layoutMode == .canvas {
            panelIsRendered = canvasModel.layout.panes.contains {
                $0.selectedPanelId.rawValue == panelId
            }
        } else {
            let selectedPanelId = bonsplitController.selectedTab(inPane: paneId)
                .flatMap { panelIdFromSurfaceId($0.id) }
            panelIsRendered = selectedPanelId == panelId || focusedPanelId == panelId
        }
        guard paneIsRendered, panelIsRendered else { return .hidden }

        let rightSidebarOwnsFocus = AppDelegate.shared?.rightSidebarOwnsInputFocus(for: self) ?? false
        return .visible(
            isActive: focusedPanelId == panelId && !rightSidebarOwnsFocus,
            zPriority: 2
        )
    }
}
