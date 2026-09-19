import Foundation

/// The catalog as one value: what the sidebar renders, what `surface.catalog` and
/// `cmux vm tree --json` print. Machines are ordered local first, then by name.
struct SurfaceCatalogSnapshot: Hashable, Codable, Sendable {
    var pendingWorkspaceDeletions: [SurfaceMachineID: Set<String>]? = nil
    var machines: [SurfaceMachineInfo]
    var resources: [SurfaceResource]
    var projections: [SurfaceProjection]

    static let empty = SurfaceCatalogSnapshot(machines: [], resources: [], projections: [])

    func resources(on machine: SurfaceMachineID) -> [SurfaceResource] {
        resources.filter { $0.machine == machine }
    }

    func projections(of resource: SurfaceResourceID) -> [SurfaceProjection] {
        projections.filter { $0.resource == resource }
    }

    func isOpen(_ resource: SurfaceResourceID) -> Bool {
        projections.contains { $0.resource == resource }
    }

}

