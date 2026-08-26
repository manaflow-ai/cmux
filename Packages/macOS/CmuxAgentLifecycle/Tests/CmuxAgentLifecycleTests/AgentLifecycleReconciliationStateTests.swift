import Foundation
import Testing
@testable import CmuxAgentLifecycle

@Suite("Agent lifecycle reconciliation")
struct AgentLifecycleReconciliationStateTests {
    @Test("An older generation cannot replace newer live evidence")
    func rejectsOlderGenerationDeliveredAfterNewerGeneration() throws {
        let panelId = UUID()
        let newer = AgentProcessGeneration(
            pid: 100,
            startSeconds: 20,
            startMicroseconds: 0
        )
        let older = AgentProcessGeneration(
            pid: 200,
            startSeconds: 10,
            startMicroseconds: 0
        )
        var state = AgentLifecycleReconciliationState()

        let acceptedNewerGeneration = state.recordProcessGeneration(
            key: BuiltInAgentIntegration.codex.statusKey,
            panelId: panelId,
            generation: newer,
            isBuiltIn: true
        )
        #expect(acceptedNewerGeneration)
        let acceptedRunningLifecycle = state.setHookLifecycle(
            key: BuiltInAgentIntegration.codex.statusKey,
            panelId: panelId,
            lifecycle: .running,
            isBuiltIn: true,
            processGeneration: newer
        )
        #expect(acceptedRunningLifecycle)

        let acceptedOlderGeneration = state.recordProcessGeneration(
            key: BuiltInAgentIntegration.codex.statusKey,
            panelId: panelId,
            generation: older,
            isBuiltIn: true
        )
        #expect(!acceptedOlderGeneration)
        #expect(
            state.resolvedStatesByPanelId[panelId]?[BuiltInAgentIntegration.codex.statusKey]
                == .running
        )
        let acceptedOlderLifecycle = state.setHookLifecycle(
            key: BuiltInAgentIntegration.codex.statusKey,
            panelId: panelId,
            lifecycle: .idle,
            isBuiltIn: true,
            processGeneration: older
        )
        #expect(!acceptedOlderLifecycle)
        #expect(
            state.resolvedStatesByPanelId[panelId]?[BuiltInAgentIntegration.codex.statusKey]
                == .running
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

        let acceptedGeneration = state.recordProcessGeneration(
            key: BuiltInAgentIntegration.amp.statusKey,
            panelId: panelId,
            generation: generation,
            isBuiltIn: true
        )
        #expect(acceptedGeneration)
        let acceptedExit = state.recordProcessExit(
            key: BuiltInAgentIntegration.amp.statusKey,
            panelId: panelId,
            generation: generation
        )
        #expect(acceptedExit)
        let acceptedResurrection = state.recordProcessGeneration(
            key: BuiltInAgentIntegration.amp.statusKey,
            panelId: panelId,
            generation: generation,
            isBuiltIn: true
        )
        #expect(!acceptedResurrection)
    }

    @Test("Delayed registration cannot replace newer exact Feed attention")
    func rejectsGenerationOlderThanExactFeedAttention() throws {
        let panelId = UUID()
        let older = AgentProcessGeneration(
            pid: 400,
            startSeconds: 40,
            startMicroseconds: 0
        )
        let newer = AgentProcessGeneration(
            pid: 500,
            startSeconds: 50,
            startMicroseconds: 0
        )
        var state = AgentLifecycleReconciliationState()

        let startedAttention = state.beginFeedAttention(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            isBuiltIn: true,
            processGeneration: newer
        )
        let token = try #require(startedAttention)
        #expect(
            state.resolvedStatesByPanelId[panelId]?[BuiltInAgentIntegration.cursor.statusKey]
                == .needsInput
        )

        let acceptedOlderGeneration = state.recordProcessGeneration(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            generation: older,
            isBuiltIn: true
        )

        #expect(!acceptedOlderGeneration)
        #expect(
            state.resolvedStatesByPanelId[panelId]?[BuiltInAgentIntegration.cursor.statusKey]
                == .needsInput
        )
        let endedAttention = state.endFeedAttention(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            token: token
        )
        #expect(endedAttention)
        #expect(
            state.resolvedStatesByPanelId[panelId]?[BuiltInAgentIntegration.cursor.statusKey]
                != .needsInput
        )
    }

    @Test("Replacement generation preserves attention without exact ownership")
    func replacementGenerationOnlyEvictsProvenOlderAttention() throws {
        let panelId = UUID()
        let older = AgentProcessGeneration(
            pid: 600,
            startSeconds: 60,
            startMicroseconds: 0
        )
        let newer = AgentProcessGeneration(
            pid: 700,
            startSeconds: 70,
            startMicroseconds: 0
        )
        var state = AgentLifecycleReconciliationState()

        let startedUnidentifiedAttention = state.beginFeedAttention(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            isBuiltIn: true
        )
        let unidentifiedToken = try #require(startedUnidentifiedAttention)
        let acceptedOlderGeneration = state.recordProcessGeneration(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            generation: older,
            isBuiltIn: true
        )
        #expect(acceptedOlderGeneration)
        let startedOlderAttention = state.beginFeedAttention(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            isBuiltIn: true
        )
        let olderToken = try #require(startedOlderAttention)

        let acceptedNewerGeneration = state.recordProcessGeneration(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            generation: newer,
            isBuiltIn: true
        )
        #expect(acceptedNewerGeneration)
        let endedOlderAttention = state.endFeedAttention(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            token: olderToken
        )
        #expect(!endedOlderAttention)
        let endedUnidentifiedAttention = state.endFeedAttention(
            key: BuiltInAgentIntegration.cursor.statusKey,
            panelId: panelId,
            token: unidentifiedToken
        )
        #expect(endedUnidentifiedAttention)
        #expect(
            state.resolvedStatesByPanelId[panelId]?[BuiltInAgentIntegration.cursor.statusKey]
                != .needsInput
        )
    }

    @Test("Process exit preserves attention without a known generation")
    func processExitPreservesUnboundFeedAttention() throws {
        let panelId = UUID()
        let generation = AgentProcessGeneration(
            pid: 800,
            startSeconds: 80,
            startMicroseconds: 0
        )
        var state = AgentLifecycleReconciliationState()

        #expect(
            state.recordProcessGeneration(
                key: BuiltInAgentIntegration.cursor.statusKey,
                panelId: panelId,
                generation: generation,
                isBuiltIn: true
            )
        )
        let token = try #require(
            state.beginFeedAttention(
                key: BuiltInAgentIntegration.cursor.statusKey,
                panelId: panelId,
                isBuiltIn: true
            )
        )

        #expect(
            state.recordProcessExit(
                key: BuiltInAgentIntegration.cursor.statusKey,
                panelId: panelId,
                generation: generation
            )
        )
        #expect(
            state.hasFeedAttention(
                key: BuiltInAgentIntegration.cursor.statusKey,
                panelId: panelId
            ),
            "An exact process exit cannot prove ownership of a nil-generation attention token."
        )
        #expect(
            state.endFeedAttention(
                key: BuiltInAgentIntegration.cursor.statusKey,
                panelId: panelId,
                token: token
            )
        )
    }
}
