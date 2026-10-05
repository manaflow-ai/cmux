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
        let working = event(3, activity: .working, nativeEvent: "PreToolUse", phase: .running)
        for input in [event(1, kind: .turnStarted), event(2, kind: .questionRequested, request: "pending-question", notification: true), working] {
            let decision = reconciler.apply(input)
            if decision.disposition != .stale && decision.projectsLifecycle {
                reducer.apply(reconciler.lifecycleEvent(input), to: &state)
            }
        }
        let session = try #require(state.sessions[surface]?["opencode"]?["first"])
        #expect(session.activity == .working)
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
