import Foundation

/// A typed relationship between two session graph nodes.
struct AgentSessionGraphEdge: Codable, Sendable, Equatable {
    var fromNodeId: String? = nil
    var fromRunId: String?
    var fromSessionId: String?
    var toNodeId: String
    var toRunId: String
    var relationship: AgentSessionRelationship

    enum CodingKeys: String, CodingKey {
        case fromNodeId = "from_node_id"
        case fromRunId = "from_run_id"
        case fromSessionId = "from_session_id"
        case toNodeId = "to_node_id"
        case toRunId = "to_run_id"
        case relationship
    }
}
