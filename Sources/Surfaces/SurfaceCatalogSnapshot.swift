import Foundation

/// The catalog as one value: what the sidebar renders, what `surface.catalog` and
/// `cmux vm tree --json` print. Machines are ordered local first, then by name.
struct SurfaceCatalogSnapshot: Hashable, Codable, Sendable {
    /// Workspaces admitted for deletion but not yet confirmed by the daemon,
    /// per machine. Nil when nothing is pending, so socket readers on older
    /// builds keep decoding the same document.
    var pendingWorkspaceDeletions: [SurfaceMachineID: Set<String>]? = nil
    var machines: [SurfaceMachineInfo]
    var resources: [SurfaceResource]
    var projections: [SurfaceProjection]
    var staleMachineIDs: Set<SurfaceMachineID> = []
    var displayCreationMachines: Set<SurfaceMachineID>? = nil

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

extension SurfaceCatalogSnapshot {
    private enum CodingKeys: String, CodingKey {
        case pendingWorkspaceDeletions, machines, resources, projections, staleMachineIDs, displayCreationMachines
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pendingWorkspaceDeletions = try values.decodeIfPresent([SurfaceMachineID: Set<String>].self, forKey: .pendingWorkspaceDeletions)
        machines = try values.decode([SurfaceMachineInfo].self, forKey: .machines)
        resources = try values.decode([SurfaceResource].self, forKey: .resources)
        projections = try values.decode([SurfaceProjection].self, forKey: .projections)
        staleMachineIDs = try values.decodeIfPresent(Set<SurfaceMachineID>.self, forKey: .staleMachineIDs) ?? []
        displayCreationMachines = try values.decodeIfPresent(Set<SurfaceMachineID>.self, forKey: .displayCreationMachines)
    }
}
