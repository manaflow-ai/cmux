import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

extension AppDelegate {
    func machineOwningBonsplitTab(_ tabID: UUID) -> SurfaceMachineID? {
        guard let source = locateContainerSurface(tabId: tabID) else { return nil }
        switch source {
        case .workspace(_, let workspace, let panelID, _):
            return workspace.machineOwningSurface(panelID)
        case .dock(let dock, let panelID):
            return dock.machineOwningSurface(panelID)
        }
    }
}
