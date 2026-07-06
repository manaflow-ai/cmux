import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func toggleFullWidthTabMode(panelId: UUID) -> Bool {
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        _ = bonsplitController.toggleFullWidthTabMode(inPane: paneId)
        focusPanel(panelId)
        return true
    }
}
