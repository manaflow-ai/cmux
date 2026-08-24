import Testing
@testable import CmuxAgentJournal

@Suite("Agent lifecycle reducer")
struct AgentLifecycleReducerTests {
    private let reducer = AgentLifecycleReducer()
    private let surface = "5E7A11AA-0000-4000-8000-000000000001"
    private let workspace = "5E7A11AA-0000-4000-8000-0000000000AA"

    private func event(
        _ sequence: Int64,
        _ kind: AgentJournalEventKind,
        session: String = "s1",
        agentKey: String = "claude_code",
        surfaceId: String? = nil,
        pendingWork: Bool = false,
        isSubagent: Bool = false,
        unattributedReason: String? = nil,
        declaredPhase: AgentLifecyclePhase? = nil
    ) -> AgentJournalEvent {
        let attributed = unattributedReason == nil
        let draft = AgentJournalEventDraft(
            eventId: "event-\(sequence)",
            kind: kind,
            occurredAtMs: 1_000 + sequence,
            source: "claude",
            agentKey: agentKey,
            sessionId: session,
            workspaceId: attributed ? workspace : nil,
            surfaceId: attributed ? (surfaceId ?? surface) : nil,
            unattributedReason: unattributedReason,
            isSubagent: isSubagent,
            pendingWork: pendingWork,
            declaredPhase: declaredPhase
        )
        return AgentJournalEvent(sequence: sequence, committedAtMs: 2_000 + sequence, draft: draft)
    }

    private func fold(_ events: [AgentJournalEvent]) -> AgentLifecycleReducerState {
        var state = AgentLifecycleReducerState()
        for event in events {
            reducer.apply(event, to: &state)
        }
        return state
    }

    @Test func basicTurnLifecycle() {
        let state = fold([
            event(1, .sessionStarted),
            event(2, .turnStarted),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)

        let idle = fold([
            event(1, .sessionStarted),
            event(2, .turnStarted),
            event(3, .turnCompleted),
        ])
        #expect(idle.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    @Test func needsInputKinds() {
        for kind in [AgentJournalEventKind.approvalRequested, .questionRequested, .planReviewRequested] {
            let state = fold([event(1, .turnStarted), event(2, kind)])
            #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .needsInput)
        }
    }

    @Test func errorReportedBecomesErrorPhase() {
        let state = fold([event(1, .turnStarted), event(2, .errorReported)])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .error)
    }

    @Test func pendingWorkKeepsTurnCompletedRunning() {
        let state = fold([event(1, .turnStarted), event(2, .turnCompleted, pendingWork: true)])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)
    }

    @Test func sessionEndedClearsEntry() {
        let state = fold([event(1, .turnStarted), event(2, .sessionEnded)])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == nil)
        #expect(state.snapshot().phases[surface] == nil)
    }

    @Test func duplicateEventsAreIdempotent() {
        let events = [event(1, .turnStarted), event(2, .approvalRequested)]
        let once = fold(events)
        let twice = fold(events + events + [events[0]])
        #expect(once == twice)
    }

    @Test func outOfOrderDeliveryConvergesToSequenceOrder() {
        let events = [
            event(1, .turnStarted),
            event(2, .approvalRequested),
            event(3, .turnStarted),
            event(4, .turnCompleted),
        ]
        let inOrder = fold(events)
        let shuffles: [[AgentJournalEvent]] = [
            [events[3], events[2], events[1], events[0]],
            [events[1], events[3], events[0], events[2]],
            [events[2], events[0], events[3], events[1]],
        ]
        for shuffled in shuffles {
            #expect(fold(shuffled).snapshot() == inOrder.snapshot())
        }
        #expect(inOrder.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    @Test func replayFromScratchReproducesState() {
        let events = [
            event(1, .sessionStarted),
            event(2, .turnStarted),
            event(3, .questionRequested),
            event(4, .turnStarted),
            event(5, .turnCompleted),
            event(6, .turnStarted),
        ]
        var incremental = AgentLifecycleReducerState()
        for entry in events {
            reducer.apply(entry, to: &incremental)
        }
        let replayed = fold(events)
        #expect(incremental == replayed)
        #expect(replayed.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)
    }

    @Test func multiSessionCombinePrecedence() {
        // Newer session running while an older session is stuck needsInput:
        // running wins (the pane is visibly busy).
        let state = fold([
            event(1, .approvalRequested, session: "old"),
            event(2, .turnStarted, session: "new"),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)

        // Once the newer session completes, the stuck old session would pin
        // needsInput — unless it ends.
        let stuck = fold([
            event(1, .approvalRequested, session: "old"),
            event(2, .turnStarted, session: "new"),
            event(3, .turnCompleted, session: "new"),
        ])
        #expect(stuck.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .needsInput)

        let cleaned = fold([
            event(1, .approvalRequested, session: "old"),
            event(2, .turnStarted, session: "new"),
            event(3, .sessionEnded, session: "old"),
            event(4, .turnCompleted, session: "new"),
        ])
        #expect(cleaned.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    @Test func subagentEventsNeverDriveSurfaceLifecycle() {
        let state = fold([event(1, .turnStarted, isSubagent: true)])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == nil)
    }

    @Test func unattributedEventsBecomeDiagnosticsNotState() {
        let state = fold([
            event(1, .approvalRequested, unattributedReason: "target-unresolved"),
        ])
        #expect(state.snapshot().phases.isEmpty)
        #expect(state.unattributedEvents.count == 1)
        #expect(state.unattributedEvents[0].draft.unattributedReason == "target-unresolved")
    }

    @Test func childAndObservationEventsKeepPhase() {
        let state = fold([
            event(1, .turnStarted),
            event(2, .childSpawned),
            event(3, .stateChanged),
            event(4, .childCompleted),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)
        // Watermark advanced: replaying event 3 changes nothing.
        var mutated = state
        let changed = reducer.apply(event(3, .stateChanged), to: &mutated)
        #expect(!changed)
        #expect(mutated == state)
    }

    @Test func observationArrivingBeforeLifecycleEventDoesNotMaskIt() {
        // A pure observation carries no watermark: a lifecycle event that
        // arrives after a higher-sequence observation still applies, so the
        // fold converges regardless of delivery order.
        let events = [
            event(1, .turnStarted),
            event(2, .stateChanged),
        ]
        let inOrder = fold(events)
        let reversed = fold([events[1], events[0]])
        #expect(inOrder.snapshot() == reversed.snapshot())
        #expect(reversed.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)
    }

    @Test func declaredPhaseCorrectionApplies() {
        let state = fold([
            event(1, .turnStarted),
            event(2, .stateChanged, declaredPhase: .idle),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    @Test func snapshotDiffProducesAssignmentsAndClears() {
        let before = fold([event(1, .turnStarted)]).snapshot()
        let after = fold([event(1, .turnStarted), event(2, .sessionEnded)]).snapshot()
        let assignments = after.assignments(since: before)
        #expect(assignments == [
            AgentLifecycleAssignment(surfaceId: surface, agentKey: "claude_code", phase: nil),
        ])

        let changed = fold([event(1, .turnStarted), event(2, .questionRequested)]).snapshot()
        #expect(changed.assignments(since: before) == [
            AgentLifecycleAssignment(surfaceId: surface, agentKey: "claude_code", phase: .needsInput),
        ])
        #expect(changed.assignments(since: changed).isEmpty)
    }

    @Test func distinctAgentsOnOneSurfaceAreIndependent() {
        let state = fold([
            event(1, .turnStarted, agentKey: "claude_code"),
            event(2, .approvalRequested, session: "s2", agentKey: "codex"),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "codex") == .needsInput)
    }
}
