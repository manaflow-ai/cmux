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

    /// A whole-pane verdict: a `stateChanged` asserting a phase with no session
    /// id, which is what a screen-reading corrector such as the scanner emits.
    private func paneAssertion(
        _ sequence: Int64,
        _ phase: AgentLifecyclePhase,
        agentKey: String = "claude_code",
        source: String = "cmux.scanner"
    ) -> AgentJournalEvent {
        let draft = AgentJournalEventDraft(
            eventId: "event-\(sequence)",
            kind: .stateChanged,
            occurredAtMs: 1_000 + sequence,
            source: source,
            agentKey: agentKey,
            sessionId: nil,
            workspaceId: workspace,
            surfaceId: surface,
            declaredPhase: phase
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

    /// A turn that finished with background work still live is finished: the
    /// pane must not keep claiming the agent is working. The outstanding work
    /// travels separately, as the flag hibernation reads, so the two questions
    /// - what is the agent doing, and may this pane sleep - stay independent.
    @Test func pendingWorkOutlivesTheTurnWithoutKeepingThePaneRunning() {
        let state = fold([event(1, .turnStarted), event(2, .turnCompleted, pendingWork: true)])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
        #expect(state.combinedPendingWork(surfaceId: surface, agentKey: "claude_code"))

        let settled = fold([event(1, .turnStarted), event(2, .turnCompleted)])
        #expect(!settled.combinedPendingWork(surfaceId: surface, agentKey: "claude_code"))
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

    /// The case every correction path exists for: a turn that started and never
    /// emitted a Stop hook, corrected by something that read the pane's screen.
    /// The correction carries no session id because the screen has no session -
    /// so it must retire the session that is stuck, not sit beside it in a
    /// bucket of its own where `running` outranks it forever.
    @Test func aPaneLevelAssertionRetiresAStuckRunningSession() {
        let state = fold([
            event(1, .turnStarted),
            paneAssertion(2, .idle),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
        #expect(state.snapshot().phases[surface]?["claude_code"] == .idle)
    }

    /// Every live session, not just one: two sessions left running on a pane
    /// are both wrong once the screen says the pane is settled.
    @Test func aPaneLevelAssertionRetiresEveryLiveSession() {
        let state = fold([
            event(1, .turnStarted, session: "old"),
            event(2, .turnStarted, session: "new"),
            paneAssertion(3, .idle),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    /// The assertion is a reading, not a verdict for all time. A real turn
    /// starting afterwards takes the pane straight back to running, so a pane
    /// corrected while idle is not stuck green once its agent resumes.
    @Test func aLaterTurnSupersedesAPaneLevelAssertion() {
        let state = fold([
            event(1, .turnStarted),
            paneAssertion(2, .idle),
            event(3, .turnStarted),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)
    }

    /// The same in the other direction, which is the trap in fixing this: an
    /// asserted `error` outranks `idle`, so unless the assertion lands in the
    /// sessions it corrects, a pane declared errored can never go green again.
    @Test func aFinishedTurnClearsAPaneLevelError() {
        let state = fold([
            event(1, .turnStarted),
            paneAssertion(2, .error),
            event(3, .turnCompleted),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    /// The pane showing a pending question while an abandoned session still
    /// claims to be working. The question outranks nothing today - `running`
    /// wins the combine - so the corrector is what has to clear the way, and it
    /// must clear only the stale claim. Erasing the question would take the one
    /// state the user has to act on and paint the pane ready.
    @Test func aPaneLevelAssertionClearsTheWayForABlockedSession() {
        let state = fold([
            event(1, .turnStarted, session: "abandoned"),
            event(2, .questionRequested, session: "live"),
            paneAssertion(3, .idle),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .needsInput)
    }

    /// Same for a session that reported an error: the screen carries no session
    /// identity, so it cannot be the thing that decides the error is over.
    @Test func aPaneLevelAssertionLeavesAnErroredSessionAlone() {
        let state = fold([
            event(1, .turnStarted, session: "abandoned"),
            event(2, .errorReported, session: "live"),
            paneAssertion(3, .idle),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .error)
    }

    /// The standalone reading is a stand-in, not a verdict: once a real session
    /// reports, the pane is described by that session. Without this a pane read
    /// as errored before its agent ever spoke could never go green again, since
    /// `error` outranks the `idle` a finished turn reports.
    @Test func aRealSessionSupersedesAStandaloneAssertion() {
        let state = fold([
            paneAssertion(1, .error),
            event(2, .turnStarted),
            event(3, .turnCompleted),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    /// But only when the session event is actually newer. An assertion that
    /// outlives an out-of-order arrival must survive it, or the fold would
    /// depend on delivery order.
    @Test func anOlderSessionEventDoesNotSupersedeANewerAssertion() {
        let events = [
            event(1, .turnCompleted),
            paneAssertion(2, .error),
        ]
        let inOrder = fold(events)
        #expect(inOrder.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .error)
        #expect(fold([events[1], events[0]]).snapshot() == inOrder.snapshot())
    }

    /// A second reading revises the first rather than piling up beside it, and
    /// the revision is still only a stand-in - a real session must still be
    /// able to take the pane back from it.
    @Test func aRevisedStandaloneReadingIsStillOnlyAStandIn() {
        let state = fold([paneAssertion(1, .idle), paneAssertion(2, .error)])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .error)

        let superseded = fold([
            paneAssertion(1, .idle),
            paneAssertion(2, .error),
            event(3, .turnStarted),
            event(4, .turnCompleted),
        ])
        #expect(superseded.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    /// A pane with no session events at all still records the assertion: the
    /// resumed agent that has never spoken is exactly the pane the corrector
    /// has to be able to describe.
    @Test func aPaneLevelAssertionStandsAloneWhenNoSessionExists() {
        let state = fold([paneAssertion(1, .idle)])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
    }

    /// Ended sessions stay ended: a correction must not resurrect a session
    /// that already reported it was finished.
    @Test func aPaneLevelAssertionDoesNotResurrectEndedSessions() {
        let state = fold([
            event(1, .turnStarted),
            event(2, .sessionEnded),
            paneAssertion(3, .idle),
        ])
        #expect(state.session(surfaceId: surface, agentKey: "claude_code", sessionKey: "s1")?.ended == true)
    }

    /// Only the agent it names: a pane running two agents must not have one
    /// agent's screen reading retire the other.
    @Test func aPaneLevelAssertionOnlyTouchesItsOwnAgentKey() {
        let state = fold([
            event(1, .turnStarted, agentKey: "claude_code"),
            event(2, .turnStarted, session: "s2", agentKey: "codex"),
            paneAssertion(3, .idle, agentKey: "claude_code"),
        ])
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "codex") == .running)
    }

    /// The fold stays a function of the event set: a correction delivered out
    /// of order must not leave a different phase than the same events in
    /// sequence order.
    @Test func paneLevelAssertionsConvergeRegardlessOfDeliveryOrder() {
        let events = [
            event(1, .turnStarted),
            paneAssertion(2, .idle),
            event(3, .turnStarted),
        ]
        let inOrder = fold(events)
        for shuffled in [
            [events[2], events[1], events[0]],
            [events[1], events[2], events[0]],
            [events[0], events[2], events[1]],
        ] {
            #expect(fold(shuffled).snapshot() == inOrder.snapshot())
        }
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
