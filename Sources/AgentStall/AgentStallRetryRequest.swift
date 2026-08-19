import Foundation

/// Immutable identity revalidated when a one-shot retry timer fires.
struct AgentStallRetryRequest: Sendable {
    let ownerToken: String
    let workspaceID: UUID
    let panelID: UUID
    let binding: SurfaceResumeBindingSnapshot
    let provider: String
    let generation: UInt64
    let attempt: Int
    let maximumAttempts: Int
    let actionID: String
    let input: String
    let processID: pid_t
    let processIdentity: AgentPIDProcessIdentity
    let token: UUID
}
