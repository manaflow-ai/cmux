import Foundation

/// The immutable presentation of one create while it is pending or recoverable.
public struct CloudMachineCreateOperation: Identifiable, Equatable, Sendable {
    /// The state visible to a machine list.
    public enum Phase: Equatable, Sendable {
        /// Creation or attachment is still running.
        case running
        /// The machine exists and awaits fleet or catalog adoption.
        case reconciling(machineID: String)
        /// Creation failed; the same request can be retried or dismissed.
        case failed(output: String)
    }

    /// The logical identity preserved through retries and authoritative adoption.
    public let id: UUID
    /// The original request; retries never change its idempotency scope.
    public let request: CloudMachineCreateRequest
    /// The time at which the reservation became visible.
    public let startedAt: Date
    /// The authoritative machine identifier, available before attach may finish.
    public internal(set) var createdMachineID: String?
    /// The current lifecycle phase.
    public internal(set) var phase: Phase = .running
    /// The server's refusal code for the failure in ``phase``, carried apart
    /// from its display text so no message can change which actions a failed
    /// row offers. Nil while running, after success, or for other failures.
    public internal(set) var refusalCode: String?
}
