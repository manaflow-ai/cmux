import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite
struct AgentRuntimeObservationTests {
    private let surface = "5E7A11AA-0000-4000-8000-000000000001"
    private let workspace = "5E7A11AA-0000-4000-8000-0000000000AA"

    private func event(_ sequence: Int64, kind: AgentJournalEventKind = .stateChanged, session: String = "first", activity: AgentSessionActivity? = nil, reason: AgentRuntimeReason? = nil, mode: AgentExecutionMode? = nil, at: Int64? = nil, generation: UInt64? = nil, request: String? = nil, notification: Bool = false, nativeEvent: String? = nil, phase: AgentLifecyclePhase? = nil) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 3_000 + sequence, draft: AgentJournalEventDraft(eventId: "runtime-\(sequence)", kind: kind, occurredAtMs: at ?? 1_000 + sequence, source: "opencode", agentKey: "opencode", sessionId: session, workspaceId: workspace, surfaceId: surface, nativeEvent: nativeEvent, declaredPhase: phase, attention: AgentAttentionContext(requestIdentity: request, notification: notification ? AgentJournalNotification(title: "Question", subtitle: "", body: "Answer", category: "needs-permission") : nil), declaredActivity: activity, declaredReason: reason, declaredMode: mode, processGeneration: generation))
    }

    private func fold(_ events: [AgentJournalEvent]) -> AgentLifecycleReducerState {
        var state = AgentLifecycleReducerState()
        let reducer = AgentLifecycleReducer()
        for event in events { reducer.apply(event, to: &state) }
        return state
    }

    @Test
    func planModeAloneCreatesNeitherWorkNorInputWait() throws {
        let state = fold([event(1, mode: .plan, generation: 999)])
        let session = try #require(state.sessions[surface]?["opencode"]?["first"])
        #expect(session.mode == .plan)
        #expect(session.activity == .unknown)
        #expect(session.phase == .unknown)
        #expect(session.activityObservedAtMs == nil)
        #expect(session.modeObservedAtMs == 1_001)
        #expect(session.modeProcessGeneration == 999)
    }

    @Test
    func modeAndActivityHaveIndependentWatermarks() throws {
        let working = event(1, kind: .turnStarted, at: 1_100, generation: 77)
        let mode = event(3, mode: .plan, at: 1_200, generation: 77)
        let inOrder = fold([working, mode])
        let reversed = fold([mode, working])
        #expect(inOrder == reversed)
        let session = try #require(reversed.sessions[surface]?["opencode"]?["first"])
        #expect(session.activity == .working)
        #expect(session.mode == .plan)
        #expect(session.lastSequence == 1)
        #expect(session.modeSequence == 3)
        #expect(session.activityObservedAtMs == 1_100)
        #expect(session.transitionedAtMs == 1_100)
        #expect(session.modeObservedAtMs == 1_200)
    }

    @Test
    func sameSurfaceSameToolRetainsWorkingAndPlanReviewSessions() throws {
        let state = fold([event(1, kind: .turnStarted), event(2, session: "second", mode: .plan), event(3, kind: .planReviewRequested, session: "second")])
        let sessions = try #require(state.sessions[surface]?["opencode"])
        #expect(sessions.count == 2)
        #expect(sessions["first"]?.activity == .working)
        #expect(sessions["second"]?.activity == .needsInput)
        #expect(sessions["second"]?.reason == .planReview)
        #expect(sessions["second"]?.mode == .plan)
        #expect(state.combinedPhase(surfaceId: surface, agentKey: "opencode") == .running)
    }

    @Test(arguments: [AgentSessionActivity.unknown, .working, .idle, .needsInput, .ready, .waiting, .quotaBlocked, .failed, .paused, .ended])
    func fullRichActivitySurvivesReduction(activity: AgentSessionActivity) throws {
        let state = fold([event(1, activity: activity, reason: .dependency, generation: 88)])
        let session = try #require(state.sessions[surface]?["opencode"]?["first"])
        #expect(session.activity == activity)
        #expect(session.reason == .dependency)
        #expect(session.processGeneration == 88)
        #expect(session.ended == (activity == .ended))
    }

    @Test
    func repeatedObservationDoesNotRestampTransitionOrLoseMode() throws {
        let state = fold([event(1, activity: .waiting, reason: .networkRetry, mode: .execution, at: 1_100), event(2, activity: .waiting, reason: .networkRetry, at: 2_200)])
        let session = try #require(state.sessions[surface]?["opencode"]?["first"])
        #expect(session.transitionedAtMs == 1_100)
        #expect(session.activityObservedAtMs == 2_200)
        #expect(session.modeObservedAtMs == 1_100)
        #expect(session.mode == .execution)
    }

    @Test
    func coarseBusyCannotClearAnUnresolvedNativeQuestion() {
        var reconciler = AgentNotificationReconciler()
        var state = AgentLifecycleReducerState()
        let reducer = AgentLifecycleReducer()
        for event in [event(1, kind: .turnStarted), event(2, kind: .questionRequested, request: "exact", notification: true), event(3, activity: .working)] {
            let decision = reconciler.apply(event)
            if decision.disposition != .stale && decision.projectsLifecycle { reducer.apply(reconciler.lifecycleEvent(event), to: &state) }
        }
        #expect(state.sessions[surface]?["opencode"]?["first"]?.activity == .needsInput)
        #expect(state.sessions[surface]?["opencode"]?["first"]?.reason == .question)
    }

    @Test
    func explicitWorkingCanCoexistWithAnUnresolvedQuestion() throws {
        var reconciler = AgentNotificationReconciler()
        var state = AgentLifecycleReducerState()
        let reducer = AgentLifecycleReducer()
        let working = event(3, activity: .working, nativeEvent: "PreToolUse")
        for input in [event(1, kind: .turnStarted), event(2, kind: .questionRequested, request: "pending-question", notification: true), working] {
            let decision = reconciler.apply(input)
            if decision.disposition != .stale && decision.projectsLifecycle {
                reducer.apply(reconciler.lifecycleEvent(input), to: &state, pendingUserActionCount: reconciler.pendingUserActionCount(for: input))
            }
        }
        let session = try #require(state.sessions[surface]?["opencode"]?["first"])
        #expect(session.activity == .working)
        #expect(session.pendingUserActionCount == 1)
        let reminder = event(4, kind: .questionRequested, notification: true)
        #expect(!reconciler.apply(reminder).projectsLifecycle)
    }

    @Test
    func olderProducerModeCannotReplaceNewerModeByArrivingLater() throws {
        let state = fold([event(1, mode: .plan, at: 2_000), event(2, mode: .execution, at: 1_000)])
        let session = try #require(state.sessions[surface]?["opencode"]?["first"])
        #expect(session.mode == .plan)
        #expect(session.modeObservedAtMs == 2_000)
    }

    @Test
    func olderProducerActivityCannotResurrectAnIdleSession() throws {
        let state = fold([event(1, activity: .idle, at: 2_000), event(2, activity: .working, at: 1_000)])
        let session = try #require(state.sessions[surface]?["opencode"]?["first"])
        #expect(session.activity == .idle)
        #expect(session.activityObservedAtMs == 2_000)
    }

    @Test
    func exactRequestsAreIndependentOfModeNotificationDeliveryAndLateReplies() {
        var reconciler = AgentNotificationReconciler()
        let first = event(1, kind: .questionRequested, request: "first", notification: false)
        let second = event(2, kind: .approvalRequested, request: "second", notification: false)
        _ = reconciler.apply(first)
        _ = reconciler.apply(second)
        #expect(reconciler.pendingUserActionCount(for: second) == 2)
        _ = reconciler.apply(event(3, mode: .plan))
        #expect(reconciler.pendingUserActionCount(for: second) == 2)
        let reply = event(4, kind: .attentionResolved, at: 900, request: "first")
        _ = reconciler.apply(reply)
        #expect(reconciler.pendingUserActionCount(for: reply) == 1)
        _ = reconciler.apply(reply)
        #expect(reconciler.pendingUserActionCount(for: reply) == 1)
        #expect(reconciler.apply(event(5, kind: .questionRequested, request: "first", notification: true)).disposition == .stale)
        _ = reconciler.apply(event(6, kind: .attentionResolved, at: 800, request: "unrelated"))
        #expect(reconciler.pendingUserActionCount(for: second) == 1)
    }

    @Test
    func ambiguousAnonymousReplyKeepsBothNativeRequests() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, kind: .questionRequested, request: "first"))
        _ = reconciler.apply(event(2, kind: .questionRequested, request: "second"))
        let reply = event(3, kind: .attentionResolved)
        _ = reconciler.apply(reply)
        #expect(reconciler.pendingUserActionCount(for: reply) == 2)
    }

    @Test
    func exactAsyncQuestionSurvivesCompletionAndNewWorkUntilItsOwnReply() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, kind: .turnStarted))
        let question = event(2, kind: .questionRequested, request: "async-question")
        _ = reconciler.apply(question)
        _ = reconciler.apply(event(3, kind: .turnCompleted))
        #expect(reconciler.pendingUserActionCount(for: question) == 1)
        _ = reconciler.apply(event(4, kind: .turnStarted))
        #expect(reconciler.pendingUserActionCount(for: question) == 1)
        _ = reconciler.apply(event(5, kind: .attentionResolved, request: "async-question"))
        #expect(reconciler.pendingUserActionCount(for: question) == 0)
        _ = reconciler.apply(event(6, kind: .questionRequested, request: "second"))
        _ = reconciler.apply(event(7, kind: .sessionEnded))
        #expect(reconciler.pendingUserActionCount(for: question) == 0)
    }

    @Test
    func claudeAliasesResolveTheSameExactRequest() {
        var questionDraft = event(1, kind: .questionRequested, request: "alias-request").draft
        questionDraft.source = "claude"
        questionDraft.agentKey = "claude_code"
        let question = AgentJournalEvent(sequence: 1, committedAtMs: 3_001, draft: questionDraft)
        var replyDraft = event(2, kind: .attentionResolved, request: "alias-request").draft
        replyDraft.source = "claude_code"
        replyDraft.agentKey = "claude_code"
        let reply = AgentJournalEvent(sequence: 2, committedAtMs: 3_002, draft: replyDraft)
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(question)
        #expect(reconciler.pendingUserActionCount(for: reply) == 1)
        _ = reconciler.apply(reply)
        #expect(reconciler.pendingUserActionCount(for: question) == 0)
    }

    @Test
    func replayReconstructsIndependentModeAndRequestEvidenceWithoutInventingWork() throws {
        let events = [event(1, mode: .plan, at: 2_000, generation: 77), event(2, kind: .questionRequested, at: 2_100, generation: 77, request: "question")]
        var reconciler = AgentNotificationReconciler()
        var state = AgentLifecycleReducerState()
        for input in events {
            let decision = reconciler.apply(input)
            if decision.disposition != .stale && decision.projectsLifecycle {
                AgentLifecycleReducer().apply(reconciler.lifecycleEvent(input), to: &state, pendingUserActionCount: reconciler.pendingUserActionCount(for: input))
            }
        }
        let session = try #require(state.sessions[surface]?["opencode"]?["first"])
        #expect(session.mode == .plan)
        #expect(session.modeObservedAtMs == 2_000)
        #expect(session.activity == .needsInput)
        #expect(session.pendingUserActionCount == 1)
        #expect(session.pendingUserActionsObservedAtMs == 2_100)
        #expect(session.pendingUserActionsProcessGeneration == 77)
        #expect(AgentJournalReplayPolicy().startupSnapshot(from: state.snapshot()).phases[surface]?["opencode"] == .needsInput)
    }

    @Test
    func structuredActivityCannotReopenIdleWithoutNewTurnOrFreshToolEvidence() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, kind: .turnStarted))
        _ = reconciler.apply(event(2, kind: .turnCompleted))
        let genericBusy = event(3, activity: .working, nativeEvent: "Notification")
        #expect(!reconciler.apply(genericBusy).projectsLifecycle)
        let tool = event(4, activity: .working, nativeEvent: "PreToolUse")
        #expect(reconciler.apply(tool).projectsLifecycle)
    }

    @Test(arguments: ["question.replied", "question.rejected"])
    func explicitResolutionCannotBeReopenedByIdleRace(nativeEvent: String) throws {
        let mapper = AgentSemanticEventMapper()
        var reconciler = AgentNotificationReconciler()
        var state = AgentLifecycleReducerState()
        let reducer = AgentLifecycleReducer()
        let events = [event(1, kind: .turnStarted), event(2, kind: .questionRequested, request: "exact-question", notification: true), event(3, kind: mapper.kind(source: "opencode", nativeEvent: nativeEvent), request: "exact-question"), event(4, kind: .idleObserved), event(5, kind: .questionRequested, request: "exact-question", notification: true)]
        var finalWasStale = false
        for event in events {
            let decision = reconciler.apply(event)
            finalWasStale = decision.disposition == .stale
            if decision.disposition != .stale && decision.projectsLifecycle { reducer.apply(reconciler.lifecycleEvent(event), to: &state) }
        }
        #expect(finalWasStale)
        #expect(state.sessions[surface]?["opencode"]?["first"]?.activity != .needsInput)
    }

    @Test
    func additiveJournalWirePreservesSemanticMetadataAndLegacyDrafts() throws {
        let original = event(1, activity: .quotaBlocked, reason: .quota, mode: .plan, generation: 123_000_007).draft
        #expect(try JSONDecoder().decode(AgentJournalEventDraft.self, from: JSONEncoder().encode(original)) == original)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["declared_activity", "declared_reason", "declared_mode", "process_generation"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(AgentJournalEventDraft.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.declaredActivity == nil)
        #expect(old.declaredMode == nil)
        #expect(old.processGeneration == nil)
        #expect(try JSONDecoder().decode(AgentExecutionMode.self, from: Data(#""build""#.utf8)) == .execution)
        #expect(try JSONDecoder().decode(AgentSessionActivity.self, from: Data(#""future""#.utf8)) == .unknown)
    }

    @Test(arguments: ["commandcode", "opencode"])
    func structuredNativeEventsAndModesMapWithoutProseInference(source: String) {
        let mapper = AgentSemanticEventMapper()
        #expect(mapper.kind(source: source, nativeEvent: "session.created") == .sessionStarted)
        #expect(mapper.kind(source: source, nativeEvent: "session.idle") == .turnCompleted)
        #expect(mapper.kind(source: source, nativeEvent: "permission.rejected") == .attentionResolved)
        #expect(mapper.mode(nativeMode: "build") == .execution)
        #expect(mapper.mode(nativeMode: "planning") == .plan)
        #expect(mapper.mode(nativeMode: "waiting for the user's plan") == nil)
    }
}
