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

    /// #20186: a forked Claude inherited another pane's agent PID, so its
    /// SessionStart was routed to the ancestor's pane and rebound that pane.
    @Test("An inherited agent PID on another terminal yields to the hook's agent")
    func inheritedAgentPIDOnAnotherTerminalYieldsToInvocationAgent() {
        let terminals: [Int: Int64] = [4_242: 0x1001, 4_343: 0x1002]
        #expect(policy.hookAgentPID(
            environmentPID: 4_242,
            invocationAgentPID: 4_343,
            controllingTerminal: { terminals[$0] }
        ) == 4_343)
    }

    @Test("An exported agent PID on the hook's terminal is kept")
    func exportedAgentPIDOnSameTerminalIsKept() {
        // A launcher shim can keep the exported PID while the agent runs as
        // its child on the same terminal; that PID still names the pane.
        let terminals: [Int: Int64] = [4_242: 0x1001, 4_343: 0x1001]
        #expect(policy.hookAgentPID(
            environmentPID: 4_242,
            invocationAgentPID: 4_343,
            controllingTerminal: { terminals[$0] }
        ) == 4_242)
    }

    @Test("Without terminal evidence the exported agent PID is kept")
    func missingTerminalEvidenceKeepsExportedPID() {
        // An exited exported PID, or a hook run without a terminal, gives no
        // evidence that the exported PID belongs to another pane.
        let terminals: [Int: Int64] = [4_343: 0x1002]
        #expect(policy.hookAgentPID(
            environmentPID: 4_242,
            invocationAgentPID: 4_343,
            controllingTerminal: { terminals[$0] }
        ) == 4_242)
        #expect(policy.hookAgentPID(
            environmentPID: 4_242,
            invocationAgentPID: 4_343,
            controllingTerminal: { $0 == 4_242 ? 0x1001 : nil }
        ) == 4_242)
        #expect(policy.hookAgentPID(
            environmentPID: nil,
            invocationAgentPID: 4_343,
            controllingTerminal: { _ in nil }
        ) == 4_343)
        #expect(policy.hookAgentPID(
            environmentPID: 4_242,
            invocationAgentPID: nil,
            controllingTerminal: { _ in 0x1001 }
        ) == 4_242)
    }

    @Test("Agent names produce stable ASCII PID environment keys")
    func pidEnvironmentKey() {
        #expect(policy.pidEnvironmentVariable(agentName: "claude") == "CMUX_CLAUDE_PID")
        #expect(policy.pidEnvironmentVariable(agentName: "future-agent") == "CMUX_FUTURE_AGENT_PID")
    }
}
