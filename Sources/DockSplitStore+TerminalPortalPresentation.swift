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
        guard panelIsSelectedInVisibleDockPane(panelId) else {
            return .hidden
        }
        return .visible(
            isActive: panelIsActiveInVisibleDockPane(panelId),
            zPriority: 1
        )
    }
}
