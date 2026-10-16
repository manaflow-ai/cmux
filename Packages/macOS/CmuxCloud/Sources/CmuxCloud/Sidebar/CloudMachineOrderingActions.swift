import CmuxCloudMachines

/// Snapshot-bound commands retained by a menu or native drag. The panel binds
/// these to its account generation; neither closure owns a copy of the order.
public struct CloudMachineOrderingActions {
    public init(
        canMove: @escaping @MainActor (String, CloudMachineMove) -> Bool,
        move: @escaping @MainActor (String, CloudMachineMove) -> [MachineSnapshot]?
    ) {
        self.canMove = canMove
        self.move = move
    }

    public let canMove: @MainActor (String, CloudMachineMove) -> Bool
    public let move: @MainActor (String, CloudMachineMove) -> [MachineSnapshot]?
}
