import CmuxCloudMachines

/// Snapshot-bound commands retained by a menu or native drag. The panel binds
/// these to its account generation; neither closure owns a copy of the order.
struct CloudMachineOrderingActions {
    let canMove: @MainActor (String, CloudMachinePinStore.Move) -> Bool
    let move: @MainActor (String, CloudMachinePinStore.Move) -> [MachineSnapshot]?
}
