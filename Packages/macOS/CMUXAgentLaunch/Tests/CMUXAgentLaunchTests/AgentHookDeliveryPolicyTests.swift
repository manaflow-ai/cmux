import Testing
@testable import CMUXAgentLaunch

@Suite("AgentHookDeliveryPolicy")
struct AgentHookDeliveryPolicyTests {
    private let policy = AgentHookDeliveryPolicy()

    @Test("Standard non-decision events are queue-safe for every agent")
    func genericEventsSupportCurrentAndFutureAgents() {
        for agent in ["claude", "codex", "future-agent"] {
            #expect(policy.supportsQueuedDelivery(agent: agent, subcommand: "prompt-submit"))
            #expect(policy.supportsQueuedDelivery(agent: agent, subcommand: "session-end"))
        }
    }

    @Test("Decision and wrapper-specific events stay out of the generic policy")
    func decisionAndAuxiliaryBoundaries() {
        #expect(!policy.supportsQueuedDelivery(agent: "future-agent", subcommand: "permission-request"))
        #expect(!policy.supportsQueuedDelivery(agent: "future-agent", subcommand: "pre-tool-use"))
        #expect(policy.supportsQueuedDelivery(agent: "claude", subcommand: "pre-tool-use"))
        #expect(policy.supportsQueuedDelivery(agent: "codex", subcommand: "post-tool-use"))
        #expect(!policy.supportsQueuedDelivery(agent: "claude", subcommand: "post-tool-use"))
        #expect(!policy.supportsQueuedDelivery(
            agent: String(repeating: "a", count: 129),
            subcommand: "session-start"
        ))
        #expect(!policy.supportsQueuedDelivery(
            agent: "claude",
            subcommand: String(repeating: "s", count: 65)
        ))
    }

    @Test("Agent names produce stable ASCII PID environment keys")
    func pidEnvironmentKey() {
        #expect(policy.pidEnvironmentVariable(agentName: "claude") == "CMUX_CLAUDE_PID")
        #expect(policy.pidEnvironmentVariable(agentName: "future-agent") == "CMUX_FUTURE_AGENT_PID")
    }
}
