import Foundation
import Testing
@testable import CmuxAgentJournal

/// A Stop click journals the interrupt so the pane leaves `running` even though
/// the agent runs no Stop hook, and a later turn runs again.
@Suite("User interrupt journal event")
struct AgentJournalUserInterruptTests {
    private let workspace = "5E7A11AA-0000-4000-8000-0000000000AA"
    private let surface = "5E7A11AA-0000-4000-8000-000000000001"

    private func hookEvent(_ sequence: Int64, _ kind: AgentJournalEventKind, source: String) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 2_000 + sequence,
            draft: AgentJournalEventDraft(eventId: "event-\(sequence)", kind: kind,
                occurredAtMs: 1_000 + sequence, source: source, agentKey: agentKey(source),
                sessionId: "session", workspaceId: workspace, surfaceId: surface,
                attention: AgentAttentionContext(turnIdentity: "turn-\(sequence)")))
    }

    private func interrupt(_ sequence: Int64, source: String) -> AgentJournalEvent {
        let draft = AgentJournalEventDraft.userInterrupt(
            source: source, agentKey: agentKey(source), sessionId: "session",
            workspaceId: workspace, surfaceId: surface,
            occurredAtMs: 1_000 + sequence
        )
        return AgentJournalEvent(sequence: sequence, committedAtMs: 2_000 + sequence, draft: draft)
    }

    private func agentKey(_ source: String) -> String {
        source == "claude" ? "claude_code" : source
    }

    /// Mirrors the journal consumer: reconcile, then reduce the lifecycle view of the event.
    private func ingest(
        _ event: AgentJournalEvent,
        reconciler: inout AgentNotificationReconciler,
        state: inout AgentLifecycleReducerState
    ) -> AgentNotificationDecision {
        let decision = reconciler.apply(event)
        if decision.disposition != .stale, decision.projectsLifecycle {
            AgentLifecycleReducer().apply(reconciler.lifecycleEvent(event), to: &state)
        }
        return decision
    }

    @Test(arguments: ["claude", "codex"])
    func interruptSettlesRunningTurnWithoutNotifying(source: String) {
        var reconciler = AgentNotificationReconciler()
        var state = AgentLifecycleReducerState()
        _ = ingest(hookEvent(1, .turnStarted, source: source), reconciler: &reconciler, state: &state)
        #expect(state.combinedPhase(surfaceId: surface, agentKey: agentKey(source)) == .running)

        let decision = ingest(interrupt(2, source: source), reconciler: &reconciler, state: &state)
        #expect(state.combinedPhase(surfaceId: surface, agentKey: agentKey(source)) == .idle)
        #expect(decision.identity == nil)

        _ = ingest(hookEvent(3, .turnStarted, source: source), reconciler: &reconciler, state: &state)
        #expect(state.combinedPhase(surfaceId: surface, agentKey: agentKey(source)) == .running)
    }

    @Test func interruptDraftIsAdmissible() {
        let draft = AgentJournalEventDraft.userInterrupt(
            source: "claude", agentKey: "claude_code", sessionId: "session",
            workspaceId: workspace, surfaceId: surface, occurredAtMs: 1_000)
        #expect(draft.validationProblem() == nil)
        #expect(draft.kind == .turnCompleted)
        #expect(draft.nativeEvent == AgentJournalEventDraft.userInterruptNativeEvent)
        #expect(draft.attention == nil)
    }

    @Test func interruptDraftsCoverOnlyRunningSessionsOnTheSurface() {
        let reducer = AgentLifecycleReducer()
        var state = AgentLifecycleReducerState()
        func event(_ sequence: Int64, _ kind: AgentJournalEventKind, session: String?, surface: String) -> AgentJournalEvent {
            AgentJournalEvent(sequence: sequence, committedAtMs: 2_000 + sequence,
                draft: AgentJournalEventDraft(eventId: "event-\(sequence)", kind: kind,
                    occurredAtMs: 1_000 + sequence, source: "claude", agentKey: "claude_code",
                    sessionId: session, workspaceId: workspace, surfaceId: surface))
        }
        let otherSurface = "5E7A11AA-0000-4000-8000-000000000002"
        for next in [
            event(1, .turnStarted, session: "running", surface: surface),
            event(2, .turnStarted, session: nil, surface: surface),
            event(3, .turnStarted, session: "idle", surface: surface),
            event(4, .turnCompleted, session: "idle", surface: surface),
            event(5, .turnStarted, session: "ended", surface: surface),
            event(6, .sessionEnded, session: "ended", surface: surface),
            event(7, .turnStarted, session: "elsewhere", surface: otherSurface),
        ] {
            reducer.apply(next, to: &state)
        }

        let boundary = state.userInterruptSessionBoundary(
            surfaceId: surface,
            agentKey: "claude_code"
        )
        let drafts = state.userInterruptDrafts(
            surfaceId: surface,
            workspaceId: workspace,
            agentKey: "claude_code",
            source: "claude",
            sessionBoundary: boundary
        )
        #expect(drafts.map(\.sessionId) == [nil, "running"])
        #expect(drafts.map(\.occurredAtMs) == [1_002, 1_001])
        #expect(drafts.allSatisfy { $0.validationProblem() == nil })

        for (offset, draft) in drafts.enumerated() {
            reducer.apply(AgentJournalEvent(sequence: 10 + Int64(offset), committedAtMs: 3_000, draft: draft), to: &state)
        }
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)
        #expect(state.combinedPhase(surfaceId: otherSurface, agentKey: "claude_code") == .running)
    }

    @Test func relayClockSkewAfterInterruptCanResumeTheTurn() throws {
        let reducer = AgentLifecycleReducer()
        var state = AgentLifecycleReducerState()
        let started = AgentJournalEvent(
            sequence: 1,
            committedAtMs: 10_000,
            draft: AgentJournalEventDraft(
                eventId: "relay-start",
                kind: .turnStarted,
                occurredAtMs: 1_000,
                source: "claude",
                agentKey: "claude_code",
                sessionId: "session",
                workspaceId: workspace,
                surfaceId: surface
            )
        )
        reducer.apply(started, to: &state)

        let boundary = state.userInterruptSessionBoundary(
            surfaceId: surface,
            agentKey: "claude_code"
        )
        let interrupts = state.userInterruptDrafts(
            surfaceId: surface,
            workspaceId: workspace,
            agentKey: "claude_code",
            source: "claude",
            sessionBoundary: boundary
        )
        #expect(interrupts.count == 1)
        let interrupt = try #require(interrupts.first)
        #expect(interrupt.occurredAtMs == 1_000)
        reducer.apply(
            AgentJournalEvent(sequence: 2, committedAtMs: 10_100, draft: interrupt),
            to: &state
        )
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .idle)

        var resumed = started.draft
        resumed.eventId = "relay-pre-tool-use"
        resumed.occurredAtMs = 1_001
        resumed.nativeEvent = "PreToolUse"
        reducer.apply(
            AgentJournalEvent(sequence: 3, committedAtMs: 10_200, draft: resumed),
            to: &state
        )
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "claude_code") == .running)
    }
}
