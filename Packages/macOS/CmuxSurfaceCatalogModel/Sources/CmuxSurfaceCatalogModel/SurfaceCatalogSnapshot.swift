import Foundation

/// The catalog as one value: what the sidebar renders, what `surface.catalog` and
/// `cmux vm tree --json` print. Machines are ordered local first, then by name.
public struct SurfaceCatalogSnapshot: Hashable, Codable, Sendable {
    /// Workspaces admitted for deletion but not yet confirmed by the daemon,
    /// per machine. Nil when nothing is pending, so socket readers on older
    /// builds keep decoding the same document.
    public var pendingWorkspaceDeletions: [SurfaceMachineID: Set<String>]? = nil
    public var machines: [SurfaceMachineInfo]
    public var resources: [SurfaceResource]
    public var projections: [SurfaceProjection]
    public var staleMachineIDs: Set<SurfaceMachineID> = []

    public static let empty = SurfaceCatalogSnapshot(machines: [], resources: [], projections: [])

    public func resources(on machine: SurfaceMachineID) -> [SurfaceResource] {
        resources.filter { $0.machine == machine }
    }

    public func projections(of resource: SurfaceResourceID) -> [SurfaceProjection] {
        projections.filter { $0.resource == resource }
    }

    public func isOpen(_ resource: SurfaceResourceID) -> Bool {
        projections.contains { $0.resource == resource }
    }


    public init(
        pendingWorkspaceDeletions: [SurfaceMachineID: Set<String>]? = nil,
        machines: [SurfaceMachineInfo],
        resources: [SurfaceResource],
        projections: [SurfaceProjection],
        staleMachineIDs: Set<SurfaceMachineID> = []
    ) {
        self.pendingWorkspaceDeletions = pendingWorkspaceDeletions
        self.machines = machines
        self.resources = resources
        self.projections = projections
        self.staleMachineIDs = staleMachineIDs
    }
}

extension SurfaceCatalogSnapshot {
    private enum CodingKeys: String, CodingKey {
        case pendingWorkspaceDeletions, machines, resources, projections, staleMachineIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pendingWorkspaceDeletions = try values.decodeIfPresent([SurfaceMachineID: Set<String>].self, forKey: .pendingWorkspaceDeletions)
        machines = try values.decode([SurfaceMachineInfo].self, forKey: .machines)
        resources = try values.decode([SurfaceResource].self, forKey: .resources)
        projections = try values.decode([SurfaceProjection].self, forKey: .projections)
        staleMachineIDs = try values.decodeIfPresent(Set<SurfaceMachineID>.self, forKey: .staleMachineIDs) ?? []
    }
}
