import Foundation

/// One resolved terminal surface that cmux recognizes as an agent target.
struct AgentPromptTerminalTarget {
    let surfaceID: UUID
    let panel: TerminalPanel
    let agentContext: String
    let agentInputScope: String
}
