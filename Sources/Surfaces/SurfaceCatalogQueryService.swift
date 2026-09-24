import Foundation

/// How much work a catalog read may do before exporting.
enum SurfaceCatalogReadMode: Equatable, Sendable {
    /// Export what the catalog already holds. Never discovers, connects, or wakes.
    case cached
    /// Ensure one machine has a connected, installed graph, then export. A
    /// machine that is already connected is served from the live catalog (its
    /// change watcher keeps the graph current), so this costs nothing on reopen.
    /// A machine that is missing or not yet linked is discovered and joins the
    /// provider's current refresh pass instead of forcing a new one.
    case linked
    /// Discover if missing, then force a new provider pass (port rescan included).
    case forced
}

/// Reads the surface catalog and resolves providers for machines not yet discovered
/// by the periodic Cloud fleet refresh. Socket entrypoints share this query owner.
@MainActor
struct SurfaceCatalogQueryService {
    private let catalog: SurfaceCatalog
    private let projectionIdentities: @MainActor ([SurfaceProjection]) -> [SurfaceProjection: SurfaceProjectionIdentity]
    private let discoverCloudMachine: @MainActor (String) async -> Void

    init(
        catalog: SurfaceCatalog,
        projectionIdentities: @escaping @MainActor ([SurfaceProjection]) -> [SurfaceProjection: SurfaceProjectionIdentity] = { _ in [:] },
        discoverCloudMachine: @escaping @MainActor (String) async -> Void
    ) {
        self.catalog = catalog
        self.projectionIdentities = projectionIdentities
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
        await read(machine: machine, mode: refresh ? .forced : .cached)
    }

    func read(machine: SurfaceMachineID?, mode: SurfaceCatalogReadMode) async -> SurfaceCatalogExport {
        switch mode {
        case .cached:
            break
        case .linked:
            // Only a machine-scoped read can ask for a link. An unfiltered
            // `.linked` read would connect every machine, which is `.forced`.
            if let machine, !isLinked(machine) {
                // A create can finish before the fleet poll sees the machine.
                // Discover it before an empty catalog is treated as unavailable.
                _ = await provider(for: machine)
                await catalog.refresh(machine: machine, force: false)
            }
        case .forced:
            if let machine {
                _ = await provider(for: machine)
                await catalog.refresh(machine: machine, force: true)
            } else {
                await catalog.refreshAll(force: true)
            }
        }
        // No suspension between the catalog export and owner-identity capture: both
        // describe the same main-actor turn, even if the pane later moves or restores.
        var export = catalog.export
        export.projectionIdentities = projectionIdentities(export.catalog.projections)
        return export
    }

    private func isLinked(_ machine: SurfaceMachineID) -> Bool {
        catalog.provider(for: machine) != nil && catalog.machineInfo(for: machine)?.linkState == .connected
    }
}
