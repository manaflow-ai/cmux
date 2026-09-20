import Foundation

extension SurfaceCatalog {
    /// Metadata updates never advance this revision. Only projection membership
    /// and coordinates can change a guest opener's routing/subscription scope.
    func noteProjectionChanges(from previous: Set<SurfaceProjection>) {
        let changed = projections.symmetricDifference(previous)
        for workspaceID in Set(changed.map(\.workspaceID)) {
            updateCloudDirectoryMetadata(localWorkspaceID: workspaceID)
        }
        for machine in Set(changed.map { $0.resource.machine }) {
            projectionVersions[machine, default: 0] &+= 1
        }
    }

    func projections(of id: SurfaceResourceID) -> [SurfaceProjection] {
        projections.filter { $0.resource == id }.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    func projectedTerminalIDs(on machine: SurfaceMachineID) -> [String] {
        Array(Set(projections.lazy.filter { $0.resource.machine == machine && $0.resource.kind == .terminal }.map { $0.resource.key })).sorted()
    }
}
