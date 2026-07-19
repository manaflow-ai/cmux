import Foundation

enum AgentProcessState: String, Codable, Sendable, Equatable {
    case alive
    case exited
    case unknown
}

enum AgentSessionLifecycleState: String, Codable, Sendable, Equatable {
    case active
    case hibernated
    case restoring
    case ended
}

enum AgentForegroundState: String, Codable, Sendable, Equatable {
    case working
    case completed
    case interrupted
    case failed
    case idle
    case unknown
}

enum AgentAttentionState: String, Codable, Sendable, Equatable {
    case none
    case needsInput = "needs_input"
    case error
    case unknown
}

enum AgentActivityState: String, Codable, Sendable, Equatable {
    case busy
    case idle
    case unknown
}

enum AgentActivityMode: String, Codable, Sendable, Equatable, CaseIterable {
    case foreground
    case background
    case monitoring
    case scheduled
    case subagents
    case tools
}

enum AgentEffectiveState: String, Codable, Sendable, Equatable {
    case working
    case monitoring
    case scheduled
    case needsInput = "needs_input"
    case interrupted
    case idle
    case hibernated
    case restoring
    case ended
    case error
    case unknown
}
