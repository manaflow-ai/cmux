import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func toggleFullWidthTabMode(panelId: UUID) -> Bool {
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        return setFullWidthTabMode(
            !bonsplitController.isFullWidthTabMode(inPane: paneId),
            panelId: panelId
        )
    }

    @discardableResult
    func setFullWidthTabMode(_ enabled: Bool, panelId: UUID) -> Bool {
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        guard bonsplitController.isFullWidthTabMode(inPane: paneId) != enabled else {
            return true
        }
        guard bonsplitController.setFullWidthTabMode(enabled, inPane: paneId),
              bonsplitController.isFullWidthTabMode(inPane: paneId) == enabled else {
            return false
        }
        focusPanel(panelId)
        return true
    }
}
