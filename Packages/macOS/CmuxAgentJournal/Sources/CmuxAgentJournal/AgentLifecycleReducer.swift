/// Deterministic fold from semantic agent events to lifecycle state.
///
/// Determinism contract (unit-tested): the fold's result is a pure function
/// of the *set* of events, independent of delivery order or re-delivery —
/// each session keeps only its newest event by journal sequence, duplicates
/// and stale arrivals are dropped, and the surface-level phase is a
/// precedence combine over live sessions.
///
/// ```swift
/// var state = AgentLifecycleReducerState()
/// let reducer = AgentLifecycleReducer()
/// for event in events { reducer.apply(event, to: &state) }
/// let snapshot = state.snapshot()
/// ```
public struct AgentLifecycleReducer: Sendable {
    /// Creates a reducer.
    public init() {}

    /// Folds one event into `state`.
    ///
    /// - Parameters:
    ///   - event: The committed journal event.
    ///   - state: The accumulated state to mutate.
    /// - Returns: `true` when the event changed lifecycle state (as opposed
    ///   to being a duplicate, stale, diagnostic-only, or non-lifecycle
    ///   event).
    @discardableResult
    public func apply(
        _ event: AgentJournalEvent,
        to state: inout AgentLifecycleReducerState
    ) -> Bool {
        state.advanceHead(to: event.sequence)
        guard event.draft.unattributedReason == nil else {
            state.recordUnattributed(event)
            return false
        }
        guard let surfaceId = event.draft.surfaceId else {
            // Attribution requires a surface: a workspace-only target would
            // make the sidebar guess a pane. Preserve as a diagnostic.
            state.recordUnattributed(event)
            return false
        }
        guard !event.draft.isSubagent else {
            // Subagent sessions never drive the hosting pane's badge.
            return false
        }
        let agentKey = event.agentKey
        let sessionKey = AgentLifecycleReducerState.sessionKey(for: event.draft)
        let previous = state.session(
            surfaceId: surfaceId,
            agentKey: agentKey,
            sessionKey: sessionKey
        )
        guard let transition = transition(for: event.draft, previous: previous) else {
            // Non-lifecycle kind: a pure observation. It deliberately does
            // not touch the session watermark, so a lifecycle event that
            // arrives after a higher-sequence observation still applies —
            // the fold stays a function of the highest-sequence
            // lifecycle-bearing event alone, independent of delivery order.
            return false
        }
        if let previous, event.sequence <= previous.lastSequence {
            // Duplicate or out-of-order stale arrival: the newest
            // lifecycle-bearing event by journal sequence already governs
            // this session.
            return false
        }
        let next = AgentSessionLifecycleState(
            phase: transition.phase,
            ended: transition.ended,
            lastSequence: event.sequence,
            lastOccurredAtMs: event.draft.occurredAtMs
        )
        let combinedBefore = state.combinedPhase(surfaceId: surfaceId, agentKey: agentKey)
        state.updateSession(
            surfaceId: surfaceId,
            agentKey: agentKey,
            sessionKey: sessionKey,
            state: next
        )
        let combinedAfter = state.combinedPhase(surfaceId: surfaceId, agentKey: agentKey)
        return combinedBefore != combinedAfter
    }

    private func transition(
        for draft: AgentJournalEventDraft,
        previous: AgentSessionLifecycleState?
    ) -> (phase: AgentLifecyclePhase, ended: Bool)? {
        switch draft.kind {
        case .sessionStarted:
            return (.unknown, false)
        case .turnStarted:
            return (.running, false)
        case .turnCompleted:
            return (draft.pendingWork ? .running : .idle, false)
        case .approvalRequested, .questionRequested, .planReviewRequested:
            return (.needsInput, false)
        case .errorReported:
            return (.error, false)
        case .sessionEnded:
            return (previous?.phase ?? .unknown, true)
        case .stateChanged:
            // Only an explicit phase assertion moves state; plain
            // state-changed events are observations.
            guard let declared = draft.declaredPhase else { return nil }
            return (declared, previous?.ended ?? false)
        case .childSpawned, .childCompleted, .childFailed:
            return nil
        }
    }
}
