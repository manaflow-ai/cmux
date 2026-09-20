import Foundation

extension SurfaceCatalog {
    func refreshPortDiscovery(machine: SurfaceMachineID) async {
        guard let provider = providers[machine] as? CmuxTuiSurfaceProvider else { return }
        provider.requestPortDiscovery()
        await provider.refresh(force: true)
    }
}
