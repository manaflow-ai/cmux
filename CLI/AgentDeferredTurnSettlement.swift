import Foundation

/// A provisional agent turn boundary waiting for structured work to drain.
struct AgentDeferredTurnSettlement: Codable, Equatable, Sendable {
    let id: UUID
    let turnId: String?
    let workspaceId: String?
    let surfaceId: String?
    let transcriptPath: String?
    let lastAssistantMessage: String?
}
