import Foundation

/// A provisional agent turn boundary waiting for structured work to drain.
struct AgentDeferredTurnSettlement: Codable, Equatable, Sendable {
    let id: UUID
    let turnId: String?
    let workspaceId: String?
    let surfaceId: String?
    let transcriptPath: String?
    let lastAssistantMessage: String?
    /// Durable single-owner replay claim. Optional fields preserve decoding of
    /// state written before overlapping hook replay was serialized.
    var replayClaimID: UUID? = nil
    var replayClaimedAt: TimeInterval? = nil
}
