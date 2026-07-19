import Foundation

/// Describes why one agent session run is related to another.
enum AgentSessionRelationship: String, Codable, Sendable {
    case spawned
    case forked
    case resumed
}
