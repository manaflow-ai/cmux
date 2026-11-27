import Foundation

/// User-initiated action sent back through the transport to resolve a
/// pending item or jump to an agent's cmux terminal.
public enum WorkstreamAction: Sendable, Equatable {
    case approvePermission(itemId: UUID, mode: WorkstreamPermissionMode)
    case replyQuestion(itemId: UUID, selections: [String])
    /// `feedback` is the user's free-form "Tell Claude what to change"
    /// text. When non-empty the hook returns a block+reason response
    /// even if `mode` is an approve variant — feedback always wins.
    case approveExitPlan(itemId: UUID, mode: WorkstreamExitPlanMode, feedback: String? = nil)
    case jumpToSession(workstreamId: String)
}
