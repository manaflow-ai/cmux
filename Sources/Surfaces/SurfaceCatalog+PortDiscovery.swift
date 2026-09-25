import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Explicit catalog refreshes are user inventory requests, so they opt a
    /// machine into demand-driven port discovery without enabling background polls.
    func requestPortDiscovery(for machine: SurfaceMachineID) {
        (provider(for: machine) as? CmuxTuiSurfaceProvider)?.requestPortDiscovery()
    }

    /// User refresh includes the metadata needed to recover a missing private address.
    func refreshPortDiscovery(machine: SurfaceMachineID) async {
        guard let provider = provider(for: machine) as? CmuxTuiSurfaceProvider else { return }
        provider.requestPortDiscovery()
        do {
            try await provider.refreshPortMetadata()
        } catch {
            guard provider.isRegisteredInCatalog(), !Task.isCancelled else { return }
            // A current private address is sufficient for the authenticated
            // daemon route. Keep scanning through that link when only the
            // control-plane metadata retry failed; without an address, surface
            // the actual blocker instead of pretending the scan was empty.
            guard provider.info.privateAddress != nil else {
                provider.portDiscovery.linkFailed()
                provider.publishPortDiscovery()
                return
            }
        }
        guard provider.isRegisteredInCatalog(), !Task.isCancelled else { return }
        await provider.refresh(force: true)
    }
}
