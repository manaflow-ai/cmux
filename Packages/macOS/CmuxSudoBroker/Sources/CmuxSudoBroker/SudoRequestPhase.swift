/// The durable, non-terminal phase of a sudo request.
public enum SudoRequestPhase: String, Codable, Sendable, Equatable {
    /// The script is waiting for an explicit user decision.
    case pendingApproval = "pending_approval"

    /// The displayed script was approved and staged for execution.
    case approved

    /// An independent runner owns the bounded sudo process tree.
    case executing
}
