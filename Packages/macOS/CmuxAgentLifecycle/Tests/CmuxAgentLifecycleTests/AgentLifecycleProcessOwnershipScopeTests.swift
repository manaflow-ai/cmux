import Testing
@testable import CmuxAgentLifecycle

@Suite("Agent lifecycle process ownership")
struct AgentLifecycleProcessOwnershipScopeTests {
    @Test("Shared-process sessions aggregate only within one process")
    func sharedProcessKeysUseExactProcessIdentity() {
        let firstGeneration = AgentProcessGeneration(
            pid: 1_001,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let firstThreadKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-a",
            processGeneration: firstGeneration
        )
        let siblingThreadKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-b",
            processGeneration: firstGeneration
        )
        let otherProcessKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-c",
            processGeneration: AgentProcessGeneration(
                pid: 2_002,
                startSeconds: 200,
                startMicroseconds: 20
            )
        )

        #expect(firstThreadKey == siblingThreadKey)
        #expect(firstThreadKey != otherProcessKey)
    }

    @Test("Missing shared-process identity falls back to the session")
    func missingProcessIdentityUsesSessionScope() {
        let firstThreadKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-a",
            processGeneration: nil
        )
        let otherThreadKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-b",
            processGeneration: nil
        )

        #expect(firstThreadKey != otherThreadKey)
    }

    @Test("Missing session IDs remain isolated by reliable process evidence")
    func emptySessionIDsDoNotCollapseAcrossProcesses() {
        let firstProcessKey = AgentLifecycleProcessOwnershipScope.session.agentPIDKey(
            statusKey: BuiltInAgentIntegration.codex.statusKey,
            sessionId: "",
            processGeneration: AgentProcessGeneration(
                pid: 1_001,
                startSeconds: 100,
                startMicroseconds: 10
            )
        )
        let otherProcessKey = AgentLifecycleProcessOwnershipScope.session.agentPIDKey(
            statusKey: BuiltInAgentIntegration.codex.statusKey,
            sessionId: "",
            processGeneration: AgentProcessGeneration(
                pid: 2_002,
                startSeconds: 200,
                startMicroseconds: 20
            )
        )

        #expect(firstProcessKey != otherProcessKey)
    }

    @Test("Missing session and process evidence fails closed")
    func missingOwnershipEvidenceProducesNoKey() {
        #expect(
            AgentLifecycleProcessOwnershipScope.session.agentPIDKey(
                statusKey: BuiltInAgentIntegration.codex.statusKey,
                sessionId: "",
                processGeneration: nil
            ) == nil
        )
        #expect(
            AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
                statusKey: BuiltInAgentIntegration.amp.statusKey,
                sessionId: "",
                processGeneration: nil
            ) == nil
        )
    }
}
