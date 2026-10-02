import Testing
@testable import CmuxAgentJournal

struct AgentSemanticAttentionRegressionTests {
    @Test(arguments: ["claude", "codex"])
    func toolResultsDoNotRequestAttention(source: String) {
        let mapper = AgentSemanticEventMapper()
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            for event in ["PostToolUse", "PostToolUseFailure", "SessionEnd"] {
                let kind = mapper.kind(source: source, nativeEvent: event, toolName: tool)
                #expect(kind != .questionRequested)
                #expect(kind != .planReviewRequested)
            }
        }
    }

    @Test(arguments: ["claude", "codex"])
    func lateCompletionCannotReplaceNewerInputWait(source: String) {
        let surface = "00000000-0000-0000-0000-000000000001"
        let workspace = "00000000-0000-0000-0000-000000000002"
        var state = AgentLifecycleReducerState()
        let reducer = AgentLifecycleReducer()
        for (sequence, occurredAt, kind) in [
            (Int64(1), Int64(100), AgentJournalEventKind.turnStarted),
            (2, 300, .approvalRequested),
            (3, 200, .turnCompleted),
        ] {
            reducer.apply(AgentJournalEvent(
                sequence: sequence,
                committedAtMs: 1000 + sequence,
                draft: AgentJournalEventDraft(
                    kind: kind, occurredAtMs: occurredAt, source: source,
                    agentKey: source, sessionId: "session", workspaceId: workspace,
                    surfaceId: surface
                )
            ), to: &state)
        }
        #expect(state.combinedPhase(surfaceId: surface, agentKey: source) == .needsInput)
    }
}
