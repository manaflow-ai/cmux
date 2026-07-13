import Foundation

/// Sanitized state for one terminal, monitor, scheduled task, subagent, or tool.
/// Commands, prompts, output, and environment values are intentionally excluded.
struct AgentWorkloadRecord: Codable, Sendable, Equatable {
    var id: String
    var kind: AgentWorkloadKind
    var phase: AgentWorkloadPhase
    var keepsSessionBusy: Bool
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    var endedAt: TimeInterval?
    var endReason: String?
}
