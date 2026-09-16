import Foundation

extension DockSplitStore {
    func machineOwningSurface(_ panelID: UUID) -> SurfaceMachineID? {
        guard panels[panelID] != nil else { return nil }
        if let machine = SurfaceCatalog.shared.machineOwningPanel(panelID), !machine.isLocal { return machine }
        return panels[panelID]?.transferredSurfaceMachine
            ?? detachedSurfaceTransfersByPanelId[panelID]?.surfaceMachine
            ?? .local
    }
}
