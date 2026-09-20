import Foundation

extension SurfaceCatalog {
    /// User refresh includes the metadata needed to recover a missing private address.
    func refreshPortDiscovery(machine: SurfaceMachineID) async {
        guard let provider = provider(for: machine) as? CmuxTuiSurfaceProvider else { return }
        provider.requestPortDiscovery()
        do {
            try await provider.refreshPortMetadata()
        } catch {
            guard provider.isRegisteredInCatalog(), !Task.isCancelled else { return }
            provider.portDiscovery.linkFailed()
            provider.publishPortDiscovery()
            return
        }
        guard provider.isRegisteredInCatalog(), !Task.isCancelled else { return }
        await provider.refresh(force: true)
    }
}
