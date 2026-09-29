import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// The panel's rows without machines whose delete the person confirmed.
/// ``MachineDeleteCoordinator`` owns which machines are hidden; its observable
/// projection invalidates every panel reading these, so a confirmed delete leaves
/// the tree, the Machines panel and every mirrored sidebar in the same frame.
extension MachinesPanelViewModel {
    /// The fleet list without machines being deleted.
    var visibleMachines: [MachineSnapshot] {
        let hidden = MachineDeleteCoordinator.shared.hiddenMachineIDs
        guard !hidden.isEmpty else { return machines }
        return machines.filter { !hidden.contains($0.id) }
    }

    /// The plan's usage without machines being deleted, so the Cloud Machines
    /// header count leaves with the row instead of at the next list read.
    var visibleUsage: CloudMachinesUsage? {
        Self.usage(plan?.usage, machines: machines, hiding: MachineDeleteCoordinator.shared.hiddenMachineIDs)
    }

    /// Takes hidden machines out of a usage counted from `machines`.
    /// - Parameters:
    ///   - usage: The plan's usage, counted at the last list read.
    ///   - machines: The fleet list that read counted.
    ///   - machineIDs: Provider machine identifiers to leave out.
    /// - Returns: The usage without those machines, or nil before the plan loads.
    static func usage(
        _ usage: CloudMachinesUsage?, machines: [MachineSnapshot], hiding machineIDs: Set<String>
    ) -> CloudMachinesUsage? {
        guard let usage, !machineIDs.isEmpty else { return usage }
        let hiddenCount = machines.count(where: { machineIDs.contains($0.id) })
        guard hiddenCount > 0 else { return usage }
        return CloudMachinesUsage(
            activeCount: max(0, usage.activeCount - hiddenCount),
            maxActiveVms: usage.maxActiveVms,
            isPaidPlan: usage.isPaidPlan
        )
    }

    /// The catalog without machines being deleted, their resources and panes.
    var visibleCatalog: SurfaceCatalogSnapshot {
        catalogHidingDeletedMachines(catalog)
    }

    /// Removes machines being deleted from a catalog snapshot.
    /// - Parameter snapshot: A catalog read, such as ``scopedCatalogSnapshot()``.
    /// - Returns: The snapshot without the hidden Cloud machines.
    func catalogHidingDeletedMachines(_ snapshot: SurfaceCatalogSnapshot) -> SurfaceCatalogSnapshot {
        Self.catalog(snapshot, hiding: MachineDeleteCoordinator.shared.hiddenMachineIDs)
    }

    /// Removes Cloud machines, their resources, panes and pending workspace changes.
    /// - Parameters:
    ///   - snapshot: A catalog read.
    ///   - machineIDs: Provider machine identifiers to leave out.
    /// - Returns: The snapshot without those machines.
    static func catalog(_ snapshot: SurfaceCatalogSnapshot, hiding machineIDs: Set<String>) -> SurfaceCatalogSnapshot {
        let hidden = Set(machineIDs.map { SurfaceMachineID.cloud($0) })
        guard !hidden.isEmpty else { return snapshot }
        var visible = snapshot
        visible.machines.removeAll { hidden.contains($0.id) }
        visible.resources.removeAll { hidden.contains($0.machine) }
        visible.projections.removeAll { hidden.contains($0.resource.machine) }
        visible.pendingWorkspaceDeletions = visible.pendingWorkspaceDeletions?.filter { !hidden.contains($0.key) }
        visible.pendingWorkspaceCreations = visible.pendingWorkspaceCreations?.filter { !hidden.contains($0.key) }
        return visible
    }
}
