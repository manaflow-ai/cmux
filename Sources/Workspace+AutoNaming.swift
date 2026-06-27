import Bonsplit
import Foundation

extension Workspace {
    func autoNamingResolvedPanelId(for requestedPanelId: UUID) -> UUID? {
        panels[requestedPanelId] != nil
            ? requestedPanelId
            : panelIdFromSurfaceId(TabID(uuid: requestedPanelId))
    }

    func canAutoNamePanel(
        requestedPanelId: UUID,
        onlyIfMultiple: Bool
    ) -> Bool {
        guard let panelId = autoNamingResolvedPanelId(for: requestedPanelId) else {
            return false
        }
        guard !(onlyIfMultiple && panels.count < 2) else {
            return false
        }
        guard panelCustomTitles[panelId] != nil else {
            return true
        }
        return panelCustomTitleSources[panelId] == .auto
    }
}
