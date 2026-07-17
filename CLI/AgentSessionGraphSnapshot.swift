import Foundation

/// A versioned, flat agent-session graph suitable for CLI automation.
struct AgentSessionGraphSnapshot: Codable, Sendable, Equatable {
    var schemaVersion: Int = 2
    var nodes: [AgentSessionGraphNode]
    var edges: [AgentSessionGraphEdge]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case nodes
        case edges
    }
}
