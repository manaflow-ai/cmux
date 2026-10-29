import Foundation

extension SurfaceCatalogSnapshot {
    /// Hides sidebar rows without destroying providers or already-open remote panes.
    ///
    /// Filters a copy so per-machine state (display creation, staleness, display
    /// memberships, pending intents) survives for the machines that stay visible.
    /// Rebuilding the value from scratch dropped `displayCreationMachines`, which
    /// made every desktop VM's New Display row report it was unavailable.
    public func applyingDeviceVisibility(
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
        var result = self
        result.machines = visibleMachines
        result.resources = visibleResources
        result.projections = projections.filter { resourceIDs.contains($0.resource) }
        result.staleMachineIDs = staleMachineIDs.intersection(machineIDs)
        let creation = displayCreationMachines?.intersection(machineIDs)
        result.displayCreationMachines = creation?.isEmpty == false ? creation : nil
        let pending = pendingDisplayCreations?.intersection(machineIDs)
        result.pendingDisplayCreations = pending?.isEmpty == false ? pending : nil
        result.cloudDisplayMemberships = cloudDisplayMemberships.filter { machineIDs.contains($0.machine) }
        result.pendingWorkspaceCreations = pendingWorkspaceCreations?.filter { machineIDs.contains($0.key) }
        result.pendingWorkspaceDeletions = pendingWorkspaceDeletions?.filter { machineIDs.contains($0.key) }
        return result
    }
}
