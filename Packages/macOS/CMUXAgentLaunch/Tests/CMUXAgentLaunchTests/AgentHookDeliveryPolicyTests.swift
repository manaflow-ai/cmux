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
            #expect(policy.supportsQueuedDelivery(agent: agent, subcommand: "shell-failed"))
        }
    }

    @Test("Decision and wrapper-specific events stay out of the generic policy")
    func decisionAndAuxiliaryBoundaries() {
        #expect(!policy.supportsQueuedDelivery(agent: "future-agent", subcommand: "permission-request"))
        #expect(!policy.supportsQueuedDelivery(agent: "future-agent", subcommand: "pre-tool-use"))
        #expect(policy.supportsQueuedDelivery(agent: "claude", subcommand: "pre-tool-use"))
        #expect(policy.supportsQueuedDelivery(agent: "codex", subcommand: "pre-tool-use"))
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

    @Test("Code Puppy lifecycle is queue-safe without borrowing Codex's tool lane")
    func codePuppyLifecycleSupportsQueuedDelivery() {
        let registration = CodePuppyAgentRegistration.standard
        // Tool status rides the generic tool-start/tool-end lane; no per-agent row.
        for event in registration.lifecycleEvents {
            #expect(policy.supportsQueuedDelivery(agent: registration.id, subcommand: event.cmuxSubcommand))
        }
        #expect(!policy.supportsQueuedDelivery(agent: registration.id, subcommand: "pre-tool-use"))
        #expect(!policy.supportsQueuedDelivery(agent: registration.id, subcommand: "post-tool-use"))
    }

    @Test("OMP and Pi headless subagent lifecycle is queue-safe")
    func ompPiSubagentEventsSupportQueuedDelivery() {
        for agent in ["omp", "pi"] {
            #expect(policy.supportsQueuedDelivery(agent: agent, subcommand: "subagent-start"))
            #expect(policy.supportsQueuedDelivery(agent: agent, subcommand: "subagent-stop"))
        }
        // Scoped to the headless wrappers: never a generic allowance.
        #expect(!policy.supportsQueuedDelivery(agent: "future-agent", subcommand: "subagent-start"))
        #expect(!policy.supportsQueuedDelivery(agent: "future-agent", subcommand: "subagent-stop"))
        #expect(!policy.supportsQueuedDelivery(agent: "claude", subcommand: "subagent-start"))
        #expect(!policy.supportsQueuedDelivery(agent: "codex", subcommand: "subagent-start"))
    }

    @Test("The queued hook answers itself before the agent kills it")
    func wallClockFitsInsideDeclaredTimeout() {
        #expect(AgentHookDeliveryPolicy.admissionWallClockSeconds
            > AgentHookDeliveryPolicy.admissionResponseTimeoutSeconds)
        // Leave at least half the declared timeout for process launch, which
        // happens before the hook can arm its own bound.
        #expect(AgentHookDeliveryPolicy.admissionWallClockSeconds * 2
            <= Double(AgentHookDeliveryPolicy.declaredTimeoutSeconds))
    }

    @Test("Agent names produce stable ASCII PID environment keys")
    func pidEnvironmentKey() {
        #expect(policy.pidEnvironmentVariable(agentName: "claude") == "CMUX_CLAUDE_PID")
        #expect(policy.pidEnvironmentVariable(agentName: "future-agent") == "CMUX_FUTURE_AGENT_PID")
    }
}
