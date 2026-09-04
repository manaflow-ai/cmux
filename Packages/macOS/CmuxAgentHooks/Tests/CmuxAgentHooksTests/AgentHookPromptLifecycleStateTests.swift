import Testing
@testable import CmuxAgentHooks

@Suite
struct AgentHookPromptLifecycleStateTests {
    @Test
    func authoritativePromptStartIsIdempotentAndReplacesStaleState() {
        var state = AgentHookPromptLifecycleState(
            depth: 4,
            activeTurnID: "stale",
            activeTurnIDs: ["stale", "nested"],
            lastTurnID: "stale"
        )

        state.beginAuthoritativePrompt(turnID: "turn-1")
        state.beginAuthoritativePrompt(turnID: "turn-2")

        #expect(state.depth == 1)
        #expect(state.activeTurnID == "turn-2")
        #expect(state.activeTurnIDs == ["turn-2"])
        #expect(state.lastTurnID == "turn-2")
    }

    @Test
    func authoritativeEndRetainsLastTurnAndClearRemovesIt() {
        var state = AgentHookPromptLifecycleState()
        state.beginAuthoritativePrompt(turnID: "turn-1")
        state.endAuthoritativePrompt()

        #expect(state.depth == nil)
        #expect(state.activeTurnID == nil)
        #expect(state.activeTurnIDs == nil)
        #expect(state.lastTurnID == "turn-1")

        state.clearPromptStartState()
        #expect(state == AgentHookPromptLifecycleState())
    }

    @Test
    func activePromptResetRetainsCompletedTurnMarker() {
        var state = AgentHookPromptLifecycleState(
            depth: 2,
            activeTurnID: "turn-active",
            activeTurnIDs: ["turn-active", "turn-nested"],
            lastTurnID: "turn-completed"
        )

        state.clearActivePromptState()

        #expect(state.depth == nil)
        #expect(state.activeTurnID == nil)
        #expect(state.activeTurnIDs == nil)
        #expect(state.lastTurnID == "turn-completed")
    }

    @Test(arguments: [
        AgentHookPromptDepthPolicy.balanced,
        AgentHookPromptDepthPolicy.authoritative,
    ])
    func policyExposesWhetherCompletionClosesAllFrames(
        _ policy: AgentHookPromptDepthPolicy
    ) {
        #expect(policy.closesActivePrompt == (policy == .authoritative))
    }
}
