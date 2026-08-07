import Foundation
import Testing
@testable import CmuxAgentLifecycle

@Suite("Agent lifecycle reconciliation")
struct AgentLifecycleReconciliationStateTests {
    @Test("An older generation cannot replace newer live evidence")
    func rejectsOlderGenerationDeliveredAfterNewerGeneration() throws {
        let panelId = UUID()
        let newer = AgentProcessGeneration(
            pid: 200,
            startSeconds: 20,
            startMicroseconds: 0
        )
        let older = AgentProcessGeneration(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 0
        )
        var state = AgentLifecycleReconciliationState()

        #expect(
            state.recordProcessGeneration(
                key: BuiltInAgentIntegration.codex.statusKey,
                panelId: panelId,
                generation: newer,
                isBuiltIn: true
            )
        )
        #expect(
            state.setHookLifecycle(
                key: BuiltInAgentIntegration.codex.statusKey,
                panelId: panelId,
                lifecycle: .running,
                isBuiltIn: true,
                processGeneration: newer
            )
        )

        #expect(
            !state.recordProcessGeneration(
                key: BuiltInAgentIntegration.codex.statusKey,
                panelId: panelId,
                generation: older,
                isBuiltIn: true
            )
        )
        #expect(
            state.resolvedStatesByPanelId[panelId]?[BuiltInAgentIntegration.codex.statusKey]
                == .running
        )
        #expect(
            !state.setHookLifecycle(
                key: BuiltInAgentIntegration.codex.statusKey,
                panelId: panelId,
                lifecycle: .idle,
                isBuiltIn: true,
                processGeneration: older
            )
        )
    }

    @Test("A dead generation cannot be resurrected")
    func rejectsGenerationMatchingExitTombstone() {
        let panelId = UUID()
        let generation = AgentProcessGeneration(
            pid: 300,
            startSeconds: 30,
            startMicroseconds: 0
        )
        var state = AgentLifecycleReconciliationState()

        #expect(
            state.recordProcessGeneration(
                key: BuiltInAgentIntegration.amp.statusKey,
                panelId: panelId,
                generation: generation,
                isBuiltIn: true
            )
        )
        #expect(
            state.recordProcessExit(
                key: BuiltInAgentIntegration.amp.statusKey,
                panelId: panelId,
                generation: generation
            )
        )
        #expect(
            !state.recordProcessGeneration(
                key: BuiltInAgentIntegration.amp.statusKey,
                panelId: panelId,
                generation: generation,
                isBuiltIn: true
            )
        )
    }
}
