import Foundation

/// Provides the per-iteration lifetime boundary for an agent inbox poll.
struct AgentInboxPollIteration {
    static func withAgentInboxPollIteration<T>(_ body: () throws -> T) rethrows -> T {
        try body()
    }
}
