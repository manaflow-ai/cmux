import Foundation

/// Stable identity for one agent root, including process birth when available.
struct AgentPortRootIdentity: Hashable, Sendable {
    let pid: Int
    let processIdentity: AgentPIDProcessIdentity?
}
