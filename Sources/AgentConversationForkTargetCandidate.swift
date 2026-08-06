import Foundation

/// One executable candidate for an installed cross-harness fork target.
struct AgentConversationForkTargetCandidate: Sendable {
    let harness: AgentConversationForkTargetHarness
    let executableURL: URL
    let runtimeSearchPath: String?
}
