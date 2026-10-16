import Foundation

/// A callback fence for one execution of a logical create, distinct on every retry.
public struct CloudMachineCreateAttempt: Hashable, Sendable {
    /// The stable operation and pending projection identity.
    public let operationID: UUID
    let generation: UUID
    let canAllocateMachine: Bool

    init(operationID: UUID, canAllocateMachine: Bool) {
        self.operationID = operationID
        self.generation = UUID()
        self.canAllocateMachine = canAllocateMachine
    }
}
