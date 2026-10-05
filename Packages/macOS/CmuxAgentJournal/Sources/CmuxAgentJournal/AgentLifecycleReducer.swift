/// Deterministic fold retaining one activity watermark and one independent mode watermark per session.
/// Mode-only observations never synthesize work or user feedback requests.
public struct AgentLifecycleReducer: Sendable {
    /// Creates a stateless reducer.
    public init() {}

    /// Folds one attributed event into the exact surface, tool, and session bucket.
    /// - Parameters:
    ///   - event: Committed native semantic event.
    ///   - state: Accumulated per-session state.
    ///   - pendingUserActionCount: Count from the native request reconciler, when supplied.
    /// - Returns: Whether activity, mode or pending-request evidence changed.
    @discardableResult
    public func apply(_ event: AgentJournalEvent, to state: inout AgentLifecycleReducerState, pendingUserActionCount: Int? = nil) -> Bool {
        state.advanceHead(to: event.sequence)
        guard event.draft.unattributedReason == nil, let surfaceId = event.draft.surfaceId else {
            state.recordUnattributed(event)
            return false
        }
        guard !event.draft.isSubagent else { return false }
        let sessionKey = AgentLifecycleReducerState.sessionKey(for: event.draft)
        let previous = state.session(surfaceId: surfaceId, agentKey: event.agentKey, sessionKey: sessionKey)
        var next = previous ?? AgentSessionLifecycleState(phase: .unknown, ended: false, lastSequence: 0, lastOccurredAtMs: 0)
        var changed = false
        if let count = pendingUserActionCount, event.sequence > next.pendingUserActionSequence,
           max(0, count) != next.pendingUserActionCount {
            next.pendingUserActionCount = max(0, count)
            next.pendingUserActionSequence = event.sequence
            next.pendingUserActionsObservedAtMs = event.draft.occurredAtMs
            next.pendingUserActionsProcessGeneration = event.draft.processGeneration
            changed = true
        }
        if let mode = event.draft.declaredMode, event.sequence > next.modeSequence,
           event.draft.occurredAtMs >= (next.modeObservedAtMs ?? Int64.min) {
            next.mode = mode
            next.modeSequence = event.sequence
            next.modeObservedAtMs = event.draft.occurredAtMs
            next.modeProcessGeneration = event.draft.processGeneration
            changed = true
        }
        if let transition = transition(for: event.draft, previous: previous),
           event.sequence > next.lastSequence,
           (event.draft.kind == .stateChanged && event.draft.declaredActivity == nil) || event.draft.occurredAtMs >= next.lastOccurredAtMs {
            let unchangedActivity = previous?.activity == transition.activity && previous?.reason == transition.reason && previous?.ended == transition.ended
            next.phase = transition.phase
            next.ended = transition.ended
            next.activity = transition.activity
            next.reason = transition.reason
            next.lastSequence = event.sequence
            next.lastOccurredAtMs = max(next.lastOccurredAtMs, event.draft.occurredAtMs)
            next.activityObservedAtMs = event.draft.occurredAtMs
            next.transitionedAtMs = unchangedActivity ? (previous?.transitionedAtMs ?? event.draft.occurredAtMs) : event.draft.occurredAtMs
            next.processGeneration = event.draft.processGeneration
            changed = true
        }
        guard changed else { return false }
        state.updateSession(surfaceId: surfaceId, agentKey: event.agentKey, sessionKey: sessionKey, state: next)
        return true
    }

    private func transition(for draft: AgentJournalEventDraft, previous: AgentSessionLifecycleState?) -> (phase: AgentLifecyclePhase, ended: Bool, activity: AgentSessionActivity, reason: AgentRuntimeReason?)? {
        if draft.kind == .stateChanged, let activity = draft.declaredActivity {
            let phase: AgentLifecyclePhase
            switch activity {
            case .working: phase = .running
            case .needsInput: phase = .needsInput
            case .failed, .quotaBlocked: phase = .error
            case .idle, .ready, .paused: phase = .idle
            case .unknown, .waiting, .ended: phase = .unknown
            }
            let reason = draft.declaredReason ?? (activity == .needsInput && previous?.activity == .needsInput ? previous?.reason : nil)
            return (phase, activity == .ended, activity, reason)
        }
        switch draft.kind {
        case .sessionStarted: return (.unknown, false, .unknown, nil)
        case .turnStarted: return (.running, false, .working, nil)
        case .attentionResolved:
            let phase = draft.declaredPhase ?? (draft.pendingWork ? .backgroundWorkPending : .idle)
            return (phase, false, phase == .running || phase == .backgroundWorkPending ? .working : .idle, nil)
        case .turnCompleted, .idleObserved:
            return draft.pendingWork ? (.backgroundWorkPending, false, .working, nil) : (.idle, false, .idle, nil)
        case .approvalRequested: return (.needsInput, false, .needsInput, .permission)
        case .questionRequested: return (.needsInput, false, .needsInput, .question)
        case .planReviewRequested: return (.needsInput, false, .needsInput, .planReview)
        case .errorReported: return (.error, false, .failed, draft.declaredReason)
        case .sessionEnded: return (previous?.phase ?? .unknown, true, .ended, .processEnded)
        case .stateChanged:
            guard let phase = draft.declaredPhase else { return nil }
            let activity: AgentSessionActivity
            switch phase {
            case .unknown: activity = .unknown
            case .running, .backgroundWorkPending: activity = .working
            case .idle: activity = .idle
            case .needsInput: activity = .needsInput
            case .error: activity = .failed
            }
            let reason = draft.declaredReason ?? (activity == .needsInput && previous?.activity == .needsInput ? previous?.reason : nil)
            return (phase, previous?.ended ?? false, activity, reason)
        case .childSpawned, .childCompleted, .childFailed, .messagePublished: return nil
        }
    }
}
