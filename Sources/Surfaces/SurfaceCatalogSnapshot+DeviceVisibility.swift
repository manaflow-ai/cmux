import Foundation

extension SurfaceCatalogSnapshot {
    /// Hides sidebar rows without destroying providers or already-open remote panes.
    func applyingDeviceVisibility(
        includesCloud: Bool,
        includesDevices: Bool,
        hiddenMacIDs: Set<String>
    ) -> SurfaceCatalogSnapshot {
        let visibleMachines = machines.filter { machine in
            if let instance = machine.id.deviceInstance {
                return includesDevices && !hiddenMacIDs.contains(instance.deviceID)
            }
            return includesCloud
        }
        let machineIDs = Set(visibleMachines.map(\.id))
        let visibleResources = resources.filter { machineIDs.contains($0.machine) }
        let resourceIDs = Set(visibleResources.map(\.id))
        return SurfaceCatalogSnapshot(
            machines: visibleMachines,
            resources: visibleResources,
            projections: projections.filter { resourceIDs.contains($0.resource) }
        )
    }
}
