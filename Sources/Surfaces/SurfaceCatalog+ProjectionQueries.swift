import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Metadata updates never advance this revision. Only projection membership
    /// and coordinates can change a guest opener's routing/subscription scope.
    func noteProjectionChanges(from previous: Set<SurfaceProjection>) {
        let changed = projections.symmetricDifference(previous)
        for workspaceID in Set(changed.map(\.workspaceID)) {
            updateCloudDirectoryMetadata(localWorkspaceID: workspaceID)
            let machines = Set(projections.filter { $0.workspaceID == workspaceID }.map { $0.resource.machine })
            if machines.isEmpty { projectionMachinesByWorkspace.removeValue(forKey: workspaceID) } else { projectionMachinesByWorkspace[workspaceID] = machines }
        }
        for machine in Set(changed.map { $0.resource.machine }) {
            projectionVersions[machine, default: 0] &+= 1
        }
    }

    func projections(of id: SurfaceResourceID) -> [SurfaceProjection] {
        projections.filter { $0.resource == id }.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    /// Returns restored projections for several resources in one catalog pass.
    /// Each resource's projections retain the stable panel ordering of `projections(of:)`.
    func projections(of ids: Set<SurfaceResourceID>) -> [SurfaceResourceID: [SurfaceProjection]] {
        var grouped: [SurfaceResourceID: [SurfaceProjection]] = [:]
        for projection in projections where ids.contains(projection.resource) {
            grouped[projection.resource, default: []].append(projection)
        }
        for id in grouped.keys {
            grouped[id]?.sort { $0.panelID.uuidString < $1.panelID.uuidString }
        }
        return grouped
    }

    /// Returns the machines projected into one workspace without scanning or sorting the catalog.
    func projectionMachines(forWorkspace workspaceID: UUID) -> Set<SurfaceMachineID> {
        var machines = projectionMachinesByWorkspace[workspaceID] ?? []
        machines.formUnion(pendingRestoredProjections.machineIDs(forWorkspace: workspaceID))
        return machines
    }

    func projectedTerminalIDs(on machine: SurfaceMachineID) -> [String] {
        Array(Set(projections.lazy.filter { $0.resource.machine == machine && $0.resource.kind == .terminal }.map { $0.resource.key })).sorted()
    }


}
