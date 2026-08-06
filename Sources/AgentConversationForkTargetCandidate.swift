import Foundation

/// One executable candidate for an installed cross-harness fork target.
struct AgentConversationForkTargetCandidate: Equatable, Hashable, Sendable {
    let harness: AgentConversationForkTargetHarness
    let executableURL: URL
    let runtimeSearchPath: String?
}
