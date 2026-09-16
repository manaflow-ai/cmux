import Foundation

extension DockSplitStore {
    func machineOwningSurface(_ panelID: UUID) -> SurfaceMachineID? {
        guard panels[panelID] != nil else { return nil }
        return detachedSurfaceTransfersByPanelId[panelID]?.surfaceMachine
            ?? SurfaceCatalog.shared.machineOwningPanel(panelID)
            ?? .local
    }
}
