import Foundation

/// Provider-neutral kinds of work owned by an agent run.
enum AgentWorkloadKind: String, Codable, Sendable, Equatable, CaseIterable {
    case foreground
    case backgroundTerminal = "background_terminal"
    case monitor
    case scheduled
    case subagent
    case tool
    case other
}
