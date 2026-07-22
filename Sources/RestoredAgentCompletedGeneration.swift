import Foundation

/// Records the process generation that a restored terminal already completed.
struct RestoredAgentCompletedGeneration: Sendable {
    let completedAt: TimeInterval
    let processIdentities: Set<AgentPIDProcessIdentity>
}
