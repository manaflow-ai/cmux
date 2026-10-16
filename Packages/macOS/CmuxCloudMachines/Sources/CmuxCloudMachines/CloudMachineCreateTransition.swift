import Foundation

/// Effects to perform only after the coordinator has committed a lifecycle transition.
public struct CloudMachineCreateTransition: Sendable {
    /// The result delivered to notification and navigation adapters.
    public enum Outcome: Equatable, Sendable {
        /// Creation and opening completed successfully.
        case created(machineID: String?, workspaceID: UUID?)
        /// The machine exists; retrying creation would allocate a duplicate.
        case createdButOpenFailed(machineID: String, output: String)
        /// No machine receipt was observed; retain the request's idempotency scope.
        case failed(output: String)
    }

    /// A completed operation paired with its outcome.
    public struct Finished: Equatable, Sendable {
        /// The operation as it was when the result arrived.
        public let operation: CloudMachineCreateOperation
        /// The result of the current attempt.
        public let outcome: Outcome
    }

    /// Whether observable state changed.
    public internal(set) var changed = false
    /// Processes to stop after cancellation tombstones have been installed.
    public internal(set) var cancelOperationIDs: [UUID] = []
    /// New machines abandoned by cancellation, deduplicated across callbacks.
    public internal(set) var cleanupMachineIDs: [String] = []
    /// Presentations the coordinator owns closing; empty for workspace-owned teardown.
    public internal(set) var closedOperations: [CloudMachineCreateOperation] = []
    /// A current completion, never a stale callback or cancelled account's result.
    public internal(set) var finished: Finished?
}
