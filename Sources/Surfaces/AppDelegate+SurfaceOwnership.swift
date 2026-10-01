import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

extension AppDelegate {
    /// Browsers hosted by this Mac are portable UI surfaces. Terminals and
    /// Cloud-owned browser/display projections still follow machine ownership.
    func surfaceOwnershipRejection(
        for tabID: UUID,
        policy: SurfaceOwnershipPolicy
    ) -> SurfaceTransferRejection? {
        guard let source = locateContainerSurface(tabId: tabID) else {
            return policy.rejection(for: nil)
        }
        switch source {
        case .workspace(_, let workspace, let panelID, _):
            let machine = workspace.machineOwningSurface(panelID)
            if workspace.panels[panelID] is BrowserPanel, machine?.isLocal != false {
                return nil
            }
            return policy.rejection(for: machine)
        case .dock(let dock, let panelID):
            let machine = dock.machineOwningSurface(panelID)
            if dock.panels[panelID] is BrowserPanel, machine?.isLocal != false {
                return nil
            }
            return policy.rejection(for: machine)
        }
    }

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
