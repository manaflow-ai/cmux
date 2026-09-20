import CmuxCloudMachines
import Foundation

/// Explicit machine pins and stable fleet order for the sidebar tree. The
/// ``CloudMachinePinStore`` is the single owner of that state; this projection
/// stamps it onto immutable row snapshots.
extension MachinesPanelViewModel {
    /// Every visible machine uses the same pin state and remembered order, including
    /// catalog discoveries that have not reached the list endpoint yet.
    var sidebarMachines: [MachineSnapshot] {
        orderedMachines(MachineSnapshotBuilder.includingCatalogMachines(machines, catalog: catalog))
    }

    @discardableResult
    func setMachinePinned(_ pinned: Bool, id: String) -> [MachineSnapshot]? {
        guard let machinePinStore, machinePinStore.scopeIdentifier != nil,
              currentMachineOrderIDs.contains(id) else { return nil }
        machinePinStore.remember(machineIDs: currentMachineOrderIDs)
        machinePinStore.setPinned(pinned, machineID: id)
        objectWillChange.send()
        return sidebarMachines
    }

    /// Captures authorization for the displayed account. A drag retains these
    /// closures even when SwiftUI installs a new action bundle during refresh.
    func bindMachineOrdering(to actions: inout MachineRowActions) {
        guard let machinePinStore, let scope = machinePinStore.scopeIdentifier else { return }
        let generation = refreshGeneration
        let pinned = machinePinStore.pinnedMachineIDs
        let isCurrent: @MainActor () -> Bool = { [weak self, weak machinePinStore] in
            self?.refreshGeneration == generation && machinePinStore?.scopeIdentifier == scope
        }
        actions.setPinned = { [weak self] id, pinned in
            guard isCurrent() else { return nil }
            return self?.setMachinePinned(pinned, id: id)
        }
        let canMove: @MainActor (String, CloudMachineMove) -> Bool = { [weak self, weak machinePinStore] id, move in
            guard isCurrent(), let self, let machinePinStore,
                  machinePinStore.isPinned(id) == pinned.contains(id) else { return false }
            return machinePinStore.canMove(move, machineID: id, machineIDs: self.currentMachineOrderIDs)
        }
        actions.ordering = CloudMachineOrderingActions(
            canMove: canMove,
            move: { [weak self, weak machinePinStore] id, move in
                guard canMove(id, move), let self, let machinePinStore,
                      machinePinStore.move(move, machineID: id, machineIDs: self.currentMachineOrderIDs) else { return nil }
                // Catalog reads are frozen while dragging; membership validation
                // must still use the latest scoped catalog, never frozen rows.
                return self.orderedMachines(
                    MachineSnapshotBuilder.includingCatalogMachines(self.machines, catalog: self.scopedCatalogSnapshot())
                )
            }
        )
    }

    private var currentMachineOrderIDs: [String] {
        MachineSnapshotBuilder.includingCatalogMachines(machines, catalog: scopedCatalogSnapshot()).map(\.id)
    }

    private func orderedMachines(_ snapshots: [MachineSnapshot]) -> [MachineSnapshot] {
        guard let machinePinStore else { return snapshots }
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return machinePinStore.orderedMachineIDs(snapshots.map(\.id)).compactMap { id in
            guard var snapshot = byID[id] else { return nil }
            snapshot.isPinned = machinePinStore.isPinned(id)
            return snapshot
        }
    }
}
