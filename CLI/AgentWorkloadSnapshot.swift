import Foundation

/// Stable public JSON shape for a sanitized workload record.
struct AgentWorkloadSnapshot: Codable, Sendable, Equatable {
    var id: String
    var kind: AgentWorkloadKind
    var phase: AgentWorkloadPhase
    var keepsSessionBusy: Bool
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    var endedAt: TimeInterval?
    var endReason: String?

    init(_ record: AgentWorkloadRecord) {
        id = record.id
        kind = record.kind
        phase = record.phase
        keepsSessionBusy = record.keepsSessionBusy
        startedAt = record.startedAt
        updatedAt = record.updatedAt
        endedAt = record.endedAt
        endReason = record.endReason
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case phase
        case keepsSessionBusy = "keeps_session_busy"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
    }
}
