import Foundation

/// The catalog as one value: what the sidebar renders, what `surface.catalog` and
/// `cmux vm tree --json` print. Machines are ordered local first, then by name.
public struct SurfaceCatalogSnapshot: Hashable, Codable, Sendable {
    /// Workspaces admitted for deletion but not yet confirmed by the daemon,
    /// per machine. Nil when nothing is pending, so socket readers on older
    /// builds keep decoding the same document.
    /// Pending native workspace identities, keyed by machine and daemon workspace.
    public var pendingWorkspaceCreations: [SurfaceMachineID: [String: UUID]]? = nil
    public var pendingWorkspaceDeletions: [SurfaceMachineID: Set<String>]? = nil
    public var machines: [SurfaceMachineInfo]
    public var resources: [SurfaceResource]
    public var projections: [SurfaceProjection]
    public var staleMachineIDs: Set<SurfaceMachineID> = []
    public var displayCreationMachines: Set<SurfaceMachineID>? = nil

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
        pendingWorkspaceCreations: [SurfaceMachineID: [String: UUID]]? = nil,
        pendingWorkspaceDeletions: [SurfaceMachineID: Set<String>]? = nil,
        machines: [SurfaceMachineInfo],
        resources: [SurfaceResource],
        projections: [SurfaceProjection],
        staleMachineIDs: Set<SurfaceMachineID> = [],
        displayCreationMachines: Set<SurfaceMachineID>? = nil
    ) {
        self.pendingWorkspaceCreations = pendingWorkspaceCreations
        self.pendingWorkspaceDeletions = pendingWorkspaceDeletions
        self.machines = machines
        self.resources = resources
        self.projections = projections
        self.staleMachineIDs = staleMachineIDs
        self.displayCreationMachines = displayCreationMachines
    }
}

extension SurfaceCatalogSnapshot {
    private enum CodingKeys: String, CodingKey {
        case pendingWorkspaceCreations, pendingWorkspaceDeletions, machines, resources, projections, staleMachineIDs, displayCreationMachines
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pendingWorkspaceCreations = try values.decodeIfPresent([SurfaceMachineID: [String: UUID]].self, forKey: .pendingWorkspaceCreations)
        pendingWorkspaceDeletions = try values.decodeIfPresent([SurfaceMachineID: Set<String>].self, forKey: .pendingWorkspaceDeletions)
        machines = try values.decode([SurfaceMachineInfo].self, forKey: .machines)
        resources = try values.decode([SurfaceResource].self, forKey: .resources)
        projections = try values.decode([SurfaceProjection].self, forKey: .projections)
        staleMachineIDs = try values.decodeIfPresent(Set<SurfaceMachineID>.self, forKey: .staleMachineIDs) ?? []
        displayCreationMachines = try values.decodeIfPresent(Set<SurfaceMachineID>.self, forKey: .displayCreationMachines)
    }
}
