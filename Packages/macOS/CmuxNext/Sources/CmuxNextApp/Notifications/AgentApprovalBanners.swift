import Foundation

/// One agent chat permission prompt a banner can answer (cx-kz6m0.2): the only pending prompt
/// of a chat on this Mac's acpmux, read when its "needs input" banner posts.
struct AgentApproval: Sendable, Equatable {
    var session: String
    var permission: String
    /// sha256 of the prompt's request (``AcpmuxPermissionFeedBridge/digest(_:)``): an answer
    /// counts only while the same request is pending.
    var digest: String
    /// What the agent asks to do (its tool call's title and command, scrubbed): the banner's body.
    var summary: String
}

/// Reads and answers an agent chat's permission prompt for its banner's Allow once and Deny.
/// The app's own is ``AcpmuxApprovalAnswerer``; tests stand in.
@MainActor
protocol AgentApprovalAnswering: AnyObject {
    /// The chat's one pending tool permission that offers allow once and a deny; nil otherwise
    /// (no prompt, a question, several prompts, or no acpmux to ask).
    func pendingApproval(session: String) async -> AgentApproval?
    /// Answers `approval` (allow once, else deny) while it is still pending unchanged; false
    /// when nothing was answered.
    func answer(_ approval: AgentApproval, allow: Bool) async -> Bool
}
