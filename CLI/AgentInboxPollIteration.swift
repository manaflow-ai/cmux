import Foundation

/// Provides the per-iteration lifetime boundary for an agent inbox poll.
struct AgentInboxPollIteration {
    /// Executes one poll iteration in a fresh autorelease pool.
    static func withAgentInboxPollIteration<T>(_ body: () throws -> T) rethrows -> T {
        try autoreleasepool(invoking: body)
    }
}
