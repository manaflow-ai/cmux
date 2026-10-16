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
        let request = provider.requestPortDiscovery()
        do {
            try await provider.refreshPortMetadata()
        } catch {
            // Pausing the machines panel's polling cancels its refreshes; a request no scan picked up must not stay loading.
            guard provider.isRegisteredInCatalog(), !Task.isCancelled else {
                provider.abandonPortDiscoveryRequest(request)
                return
            }
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
        guard provider.isRegisteredInCatalog(), !Task.isCancelled else {
            provider.abandonPortDiscoveryRequest(request)
            return
        }
        await provider.refresh(force: true)
        // The cancel can land during display discovery, after which the graph refresh runs no pass.
        if Task.isCancelled { provider.abandonPortDiscoveryRequest(request) }
    }
}
