public import AppKit

/// Agent sign-ins with canned data, for tests and DEBUG launches: records each read's
/// `recheck` and each Sign In's id; never runs a login.
@MainActor
public final class MockAgentSignInSource: AgentSignInSource {
    public var agents: [OnboardingAgent]
    /// What Sign In answers: whether a terminal tab opened.
    public var signInOpens = true
    /// What Install answers: nil when it installed (the agent then reads as installed), else the error.
    public var installFails: String?
    public private(set) var installsRun: [String] = []
    public private(set) var reads: [Bool] = []
    public private(set) var signIns: [String] = []
    /// The next read waits until ``heldRead`` is resumed (tests that race two reads); it answers the agents as
    /// they are then.
    public var holdNextRead = false
    public private(set) var heldRead: CheckedContinuation<Void, Never>?

    public init(agents: [OnboardingAgent] = []) {
        self.agents = agents
    }

    public func agentSignIns(recheck: Bool) async -> [OnboardingAgent] {
        reads.append(recheck)
        if holdNextRead {
            holdNextRead = false
            await withCheckedContinuation { heldRead = $0 }
        }
        return agents
    }

    public func signInAgent(_ id: String) async -> Bool {
        signIns.append(id)
        return signInOpens
    }

    public func installAgent(_ id: String) async -> String? {
        installsRun.append(id)
        if let installFails { return installFails }
        agents = agents.map {
            $0.id == id ? OnboardingAgent(id: $0.id, name: $0.name, brand: $0.brand, auth: .signedOut) : $0
        }
        return nil
    }

    public func agentIcon(_ agent: OnboardingAgent, side: CGFloat) -> NSImage? { nil }
}
