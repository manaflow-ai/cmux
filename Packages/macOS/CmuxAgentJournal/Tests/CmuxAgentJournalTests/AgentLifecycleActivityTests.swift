import Testing
@testable import CmuxAgentJournal

@Suite("Agent lifecycle activity")
struct AgentLifecycleActivityTests {
    @Test func turnBoundariesAndRequestsForTheUserAreMeaningful() {
        #expect(AgentLifecycleActivity.classify(from: .running, to: .idle) == .turnFinished)
        #expect(AgentLifecycleActivity.classify(from: .running, to: .needsInput) == .needsInput)
        #expect(AgentLifecycleActivity.classify(from: .idle, to: .needsInput) == .needsInput)
        #expect(AgentLifecycleActivity.classify(from: .running, to: .error) == .error)
        #expect(AgentLifecycleActivity.classify(from: .idle, to: .running) == .promptSubmitted)
        #expect(AgentLifecycleActivity.classify(from: nil, to: .running) == .promptSubmitted)
        #expect(AgentLifecycleActivity.classify(from: .unknown, to: .running) == .promptSubmitted)
    }

    @Test func stepsInsideATurnAreNotMeaningful() {
        // Tool calls and streamed output keep the combined phase at running.
        #expect(AgentLifecycleActivity.classify(from: .running, to: .running) == nil)
        #expect(AgentLifecycleActivity.classify(from: .idle, to: .idle) == nil)
        #expect(AgentLifecycleActivity.classify(from: .needsInput, to: .needsInput) == nil)
    }

    @Test func resumingEndingAndUnknownAreNotMeaningful() {
        #expect(AgentLifecycleActivity.classify(from: .needsInput, to: .running) == nil)
        #expect(AgentLifecycleActivity.classify(from: .error, to: .running) == nil)
        #expect(AgentLifecycleActivity.classify(from: .running, to: nil) == nil)
        #expect(AgentLifecycleActivity.classify(from: .running, to: .unknown) == nil)
        #expect(AgentLifecycleActivity.classify(from: nil, to: .idle) == nil)
        #expect(AgentLifecycleActivity.classify(from: .unknown, to: .idle) == nil)
    }

    @Test func correctionsAndSessionBookkeepingNeverCount() {
        #expect(AgentLifecycleActivity.classify(event: .stateChanged, from: .running, to: .idle) == nil)
        #expect(AgentLifecycleActivity.classify(event: .sessionEnded, from: .running, to: nil) == nil)
        #expect(AgentLifecycleActivity.classify(event: .sessionStarted, from: nil, to: .unknown) == nil)
        #expect(AgentLifecycleActivity.classify(event: .turnCompleted, from: .running, to: .idle) == .turnFinished)
        #expect(AgentLifecycleActivity.classify(event: .approvalRequested, from: .running, to: .needsInput) == .needsInput)
    }

    @Test func onlyATurnStartIsANewPrompt() {
        #expect(AgentLifecycleActivity.classify(event: .turnStarted, from: .idle, to: .running) == .promptSubmitted)
        #expect(AgentLifecycleActivity.classify(event: .childSpawned, from: .idle, to: .running) == nil)
        #expect(AgentLifecycleActivity.classify(event: .turnStarted, from: .error, to: .running) == .promptSubmitted)
        #expect(AgentLifecycleActivity.classify(event: .turnStarted, from: .needsInput, to: .running) == nil)
        #expect(AgentLifecycleActivity.classify(event: .turnStarted, from: .running, to: .running) == nil)
        #expect(AgentLifecycleActivity.classify(event: .attentionResolved, from: .needsInput, to: .running) == nil)
        #expect(AgentLifecycleActivity.classify(event: .childCompleted, from: .running, to: .idle) == .turnFinished)
        #expect(AgentLifecycleActivity.classify(event: .idleObserved, from: .running, to: .idle) == .turnFinished)
    }

    @Test func reducedEventsClassifyThroughTheCombinedPhase() {
        let reducer = AgentLifecycleReducer()
        var state = AgentLifecycleReducerState()
        let surface = "5E7A11AA-0000-4000-8000-000000000001"
        let workspace = "5E7A11AA-0000-4000-8000-0000000000AA"
        var sequence: Int64 = 0
        func step(_ kind: AgentJournalEventKind) -> AgentLifecycleActivity? {
            sequence += 1
            let before = state.combinedPhase(surfaceId: surface, agentKey: "claude_code")
            let draft = AgentJournalEventDraft(
                eventId: "event-\(sequence)",
                kind: kind,
                occurredAtMs: 1_000 + sequence,
                source: "claude",
                agentKey: "claude_code",
                sessionId: "s1",
                workspaceId: workspace,
                surfaceId: surface
            )
            reducer.apply(
                AgentJournalEvent(sequence: sequence, committedAtMs: 1_000 + sequence, draft: draft),
                to: &state
            )
            return AgentLifecycleActivity.classify(
                event: kind,
                from: before,
                to: state.combinedPhase(surfaceId: surface, agentKey: "claude_code")
            )
        }

        #expect(step(.turnStarted) == .promptSubmitted)
        // Intermediate steps inside the turn.
        #expect(step(.stateChanged) == nil)
        #expect(step(.childSpawned) == nil)
        #expect(step(.childCompleted) == nil)
        #expect(step(.turnCompleted) == .turnFinished)
    }
}
