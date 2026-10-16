import Testing
@testable import CmuxAgentJournal

struct AgentNeedsInputStopContextTests {
    @Test func matchingQuestionTurnPreservesNeedsInput() {
        let context = AgentNeedsInputStopContext(
            runtimePhase: .needsInput,
            activePromptDepth: 1,
            activePromptTurnIDs: ["turn-1"],
            inputTurnID: "turn-1"
        )
        #expect(context.shouldPreserveNeedsInput)
    }

    @Test(arguments: ["session_shutdown", "cancelled", "aborted", "interrupted", "terminated"])
    func terminalReasonsClearNeedsInput(reason: String) {
        let context = AgentNeedsInputStopContext(
            runtimePhase: .needsInput,
            activePromptDepth: 1,
            activePromptTurnID: "turn-1",
            inputTurnID: "turn-1",
            terminationReason: reason
        )
        #expect(!context.shouldPreserveNeedsInput)
    }

    @Test func mismatchedTurnDoesNotPreserveNeedsInput() {
        let context = AgentNeedsInputStopContext(
            runtimePhase: .needsInput,
            activePromptDepth: 1,
            activePromptTurnIDs: ["turn-1"],
            lastPromptTurnID: "turn-1",
            inputTurnID: "turn-2"
        )
        #expect(!context.shouldPreserveNeedsInput)
    }

    @Test func promptDepthAllowsLegacyStopWithoutTurnID() {
        let context = AgentNeedsInputStopContext(
            runtimePhase: .needsInput,
            activePromptDepth: 1
        )
        #expect(context.shouldPreserveNeedsInput)
    }

    @Test func otherPhasesNeverPreserveNeedsInput() {
        for phase in AgentLifecyclePhase.allCases where phase != .needsInput {
            let context = AgentNeedsInputStopContext(
                runtimePhase: phase,
                activePromptDepth: 1,
                activePromptTurnID: "turn-1"
            )
            #expect(!context.shouldPreserveNeedsInput)
        }
    }
}
