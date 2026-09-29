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
