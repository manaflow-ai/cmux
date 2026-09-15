import Foundation

/// Reads the surface catalog and resolves providers for machines not yet discovered
/// by the periodic Cloud fleet refresh. Socket entrypoints share this query owner.
@MainActor
struct SurfaceCatalogQueryService {
    private let catalog: SurfaceCatalog
    private let discoverCloudMachine: @MainActor (String) async -> Void

    init(
        catalog: SurfaceCatalog,
        discoverCloudMachine: @escaping @MainActor (String) async -> Void
    ) {
        self.catalog = catalog
        self.discoverCloudMachine = discoverCloudMachine
    }

    /// Existing providers are local lookups; only a missing Cloud machine needs
    /// a control-plane discovery before its provider can be used.
    func provider(for machine: SurfaceMachineID) async -> (any SurfaceProvider)? {
        if let provider = catalog.provider(for: machine) { return provider }
        guard case .cloud(let id) = machine else { return nil }
        await discoverCloudMachine(id)
        return catalog.provider(for: machine)
    }

    func read(machine: SurfaceMachineID?, refresh: Bool) async -> SurfaceCatalogExport {
        if refresh {
            if let machine {
                // A create can finish before the fleet poll sees the machine.
                // Discover it before an empty catalog is treated as unavailable.
                _ = await provider(for: machine)
                await catalog.refresh(machine: machine, force: true)
            } else {
                await catalog.refreshAll(force: true)
            }
        }
        return catalog.export
    }
}
