import Foundation

/// One resolved terminal surface that cmux recognizes as an agent target.
@MainActor
struct AgentPromptTerminalTarget {
    let surfaceID: UUID
    let panel: TerminalPanel
    let agentContext: String
    /// Composer ownership, or `nil` while the agent process identity is unavailable.
    let agentInputScope: String?
}
