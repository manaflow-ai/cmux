import Testing
@testable import CmuxAgentLifecycle

@Suite("Agent turn settlement")
struct AgentTurnSettlementReconcilerTests {
    @Test("Amp requires its explicit settled boundary")
    func ampKeepsRunningAtProvisionalBoundary() {
        let decision = AgentTurnSettlementReconciler().resolve(
            integration: .amp,
            evidence: AgentTurnSettlementEvidence(
                boundary: .turnEnd,
                activeBackgroundWorkCount: 0,
                processLiveness: .live,
                turnFreshness: .current
            )
        )

        #expect(decision == .keepRunning)
    }

    @Test("A dead generation terminates without completion")
    func exitedGenerationDoesNotPublishSuccess() {
        let decision = AgentTurnSettlementReconciler().resolve(
            integration: .codex,
            evidence: AgentTurnSettlementEvidence(
                boundary: .settled,
                activeBackgroundWorkCount: 0,
                processLiveness: .exited,
                turnFreshness: .current
            )
        )

        #expect(decision == .terminateWithoutCompletion)
    }

    @Test("Active structured work withholds completion")
    func activeBackgroundWorkKeepsRunning() {
        let decision = AgentTurnSettlementReconciler().resolve(
            integration: .codex,
            evidence: AgentTurnSettlementEvidence(
                boundary: .settled,
                activeBackgroundWorkCount: 1,
                processLiveness: .live,
                turnFreshness: .current
            )
        )

        #expect(decision == .keepRunning)
    }

    @Test("A superseded turn cannot publish completion")
    func supersededTurnKeepsRunning() {
        let decision = AgentTurnSettlementReconciler().resolve(
            integration: .codex,
            evidence: AgentTurnSettlementEvidence(
                boundary: .settled,
                activeBackgroundWorkCount: 0,
                processLiveness: .live,
                turnFreshness: .superseded
            )
        )

        #expect(decision == .keepRunning)
    }
}
