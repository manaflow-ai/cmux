import Foundation

/// Query-friendly aggregate over active workloads without hiding workload detail.
struct AgentActivitySnapshot: Codable, Sendable, Equatable {
    struct Counts: Codable, Sendable, Equatable {
        var foreground = 0
        var backgroundTerminal = 0
        var monitor = 0
        var scheduled = 0
        var subagent = 0
        var tool = 0
        var other = 0

        enum CodingKeys: String, CodingKey {
            case foreground
            case backgroundTerminal = "background_terminal"
            case monitor
            case scheduled
            case subagent
            case tool
            case other
        }

        var total: Int {
            foreground + backgroundTerminal + monitor + scheduled + subagent + tool + other
        }
    }

    var state: AgentActivityState
    var busy: Bool
    var modes: [AgentActivityMode]
    var counts: Counts
}
