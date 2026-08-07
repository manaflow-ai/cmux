import Testing
@testable import CmuxAgentLifecycle

@Suite("Agent lifecycle process ownership")
struct AgentLifecycleProcessOwnershipScopeTests {
    @Test("Shared-process sessions aggregate only within one process")
    func sharedProcessKeysUseExactProcessIdentity() {
        let firstThreadKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-a",
            processID: 1_001
        )
        let siblingThreadKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-b",
            processID: 1_001
        )
        let otherProcessKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-c",
            processID: 2_002
        )

        #expect(firstThreadKey == siblingThreadKey)
        #expect(firstThreadKey != otherProcessKey)
    }

    @Test("Missing shared-process identity falls back to the session")
    func missingProcessIdentityUsesSessionScope() {
        let firstThreadKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-a",
            processID: nil
        )
        let otherThreadKey = AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
            statusKey: BuiltInAgentIntegration.amp.statusKey,
            sessionId: "thread-b",
            processID: nil
        )

        #expect(firstThreadKey != otherThreadKey)
    }
}
