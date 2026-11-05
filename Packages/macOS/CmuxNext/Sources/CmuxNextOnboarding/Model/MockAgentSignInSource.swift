public import AppKit

/// Agent sign-ins with canned data, for tests and DEBUG launches: records each read's
/// `recheck` and each Sign In's id; never runs a login.
@MainActor
public final class MockAgentSignInSource: AgentSignInSource {
    public var agents: [OnboardingAgent]
    /// What Sign In answers: whether a terminal tab opened.
    public var signInOpens = true
    public private(set) var reads: [Bool] = []
    public private(set) var signIns: [String] = []

    public init(agents: [OnboardingAgent] = []) {
        self.agents = agents
    }

    public func agentSignIns(recheck: Bool) async -> [OnboardingAgent] {
        reads.append(recheck)
        return agents
    }

    public func signInAgent(_ id: String) async -> Bool {
        signIns.append(id)
        return signInOpens
    }

    public func agentIcon(_ agent: OnboardingAgent, side: CGFloat) -> NSImage? { nil }
}
