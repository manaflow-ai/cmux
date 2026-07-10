import Foundation

/// Records the process and hook generation that a restored terminal already completed.
struct RestoredAgentCompletedGeneration: Sendable {
    let completedAt: TimeInterval
    let updatedAt: TimeInterval
    let processIdentities: Set<AgentPIDProcessIdentity>
}
