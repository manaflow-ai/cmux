import Foundation

/// A typed relationship between two session graph nodes.
struct AgentSessionGraphEdge: Codable, Sendable, Equatable {
    var fromRunId: String?
    var fromSessionId: String?
    var toRunId: String
    var relationship: AgentSessionRelationship

    enum CodingKeys: String, CodingKey {
        case fromRunId = "from_run_id"
        case fromSessionId = "from_session_id"
        case toRunId = "to_run_id"
        case relationship
    }
}
