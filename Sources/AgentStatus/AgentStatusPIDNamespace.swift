/// Host namespace in which an agent PID is meaningful.
enum AgentStatusPIDNamespace: String, Codable, Equatable, Sendable {
    case local
    case remote
}
