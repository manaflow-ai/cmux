import CmuxCloudMachines
import Foundation

/// Explicit machine pins and stable fleet order for the sidebar tree. The
/// ``CloudMachinePinStore`` is the single owner of that state; this projection
/// stamps it onto immutable row snapshots.
extension MachinesPanelViewModel {
    /// Every visible machine uses the same pin state and remembered order, including
    /// catalog discoveries that have not reached the list endpoint yet.
    var sidebarMachines: [MachineSnapshot] {
        let snapshots = MachineSnapshotBuilder.includingCatalogMachines(machines, catalog: catalog).map { machine in
            var next = machine
            next.isPinned = machinePinStore?.isPinned(machine.id) == true
            return next
        }
        return orderedMachines(snapshots)
    }

    func setMachinePinned(_ pinned: Bool, id: String) {
        guard let machinePinStore, sidebarMachines.contains(where: { $0.id == id }) else { return }
        machinePinStore.remember(machineIDs: sidebarMachines.map(\.id))
        machinePinStore.setPinned(pinned, machineID: id)
        objectWillChange.send()
    }

    private func orderedMachines(_ snapshots: [MachineSnapshot]) -> [MachineSnapshot] {
        guard let machinePinStore else { return snapshots }
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return machinePinStore.orderedMachineIDs(snapshots.map(\.id)).compactMap { byID[$0] }
    }
}
