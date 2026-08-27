/// Deterministic fold from semantic agent events to lifecycle state.
///
/// Determinism contract (unit-tested): the fold's result is a pure function
/// of the *set* of events, independent of delivery order or re-delivery —
/// each session keeps only its newest event by journal sequence, duplicates
/// and stale arrivals are dropped, and the surface-level phase is a
/// precedence combine over live sessions. A whole-pane assertion writes into
/// every live session rather than a bucket of its own, which keeps that
/// property: it is dropped by the same per-session watermark when a newer
/// session event has already superseded it.
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
        let combinedBefore = state.combinedPhase(surfaceId: surfaceId, agentKey: agentKey)
        let pendingBefore = state.combinedPendingWork(surfaceId: surfaceId, agentKey: agentKey)
        var applied = false
        for sessionKey in targetSessionKeys(
            for: event.draft,
            surfaceId: surfaceId,
            agentKey: agentKey,
            in: state
        ) {
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
                continue
            }
            if let previous, event.sequence <= previous.lastSequence {
                // Duplicate or out-of-order stale arrival: the newest
                // lifecycle-bearing event by journal sequence already governs
                // this session.
                continue
            }
            state.updateSession(
                surfaceId: surfaceId,
                agentKey: agentKey,
                sessionKey: sessionKey,
                state: AgentSessionLifecycleState(
                    phase: transition.phase,
                    ended: transition.ended,
                    lastSequence: event.sequence,
                    lastOccurredAtMs: event.draft.occurredAtMs,
                    pendingWork: event.draft.pendingWork
                )
            )
            applied = true
        }
        guard applied else { return false }
        let combinedAfter = state.combinedPhase(surfaceId: surfaceId, agentKey: agentKey)
        let pendingAfter = state.combinedPendingWork(surfaceId: surfaceId, agentKey: agentKey)
        return combinedBefore != combinedAfter || pendingBefore != pendingAfter
    }

    /// The session buckets an event writes into.
    ///
    /// One, normally: the session the event names. A whole-pane assertion (see
    /// ``AgentLifecycleReducerState/isPaneLevelAssertion(_:)``) instead writes
    /// into every live session on the surface, because it is correcting them
    /// rather than reporting alongside them — a correction filed in a bucket of
    /// its own can never beat a session left claiming `running`, which is the
    /// only state it is ever emitted for.
    ///
    /// With no live session to correct it falls back to its own bucket, so a
    /// reading of a pane whose agent has never emitted an event is still
    /// recorded. When every live session is newer than the assertion it targets
    /// nothing and is dropped, which keeps the fold order-independent.
    ///
    /// - Parameters:
    ///   - draft: The event's draft.
    ///   - surfaceId: The attributed surface.
    ///   - agentKey: The event's agent key.
    ///   - state: The state being folded into.
    /// - Returns: The session keys to write.
    private func targetSessionKeys(
        for draft: AgentJournalEventDraft,
        surfaceId: String,
        agentKey: String,
        in state: AgentLifecycleReducerState
    ) -> [String] {
        let ownKey = AgentLifecycleReducerState.sessionKey(for: draft)
        guard AgentLifecycleReducerState.isPaneLevelAssertion(draft) else { return [ownKey] }
        let live = state.liveSessionKeys(surfaceId: surfaceId, agentKey: agentKey)
        return live.isEmpty ? [ownKey] : live
    }

    private func transition(
        for draft: AgentJournalEventDraft,
        previous: AgentSessionLifecycleState?
    ) -> (phase: AgentLifecyclePhase, ended: Bool)? {
        switch draft.kind {
        case .sessionStarted:
            // A session that is starting is present and ready, not stateless:
            // `unknown` renders as "no agent in this pane", so a freshly started
            // or resumed agent read as a plain terminal until its first turn.
            //
            // A resume keeps whatever phase the session already had - startup
            // replay restores a pending question or a spent quota, and starting
            // the agent back up must not blank that.
            return (previous?.phase ?? .idle, false)
        case .turnStarted:
            return (.running, false)
        case .turnCompleted:
            // Always idle: the turn is over. Outstanding background work is
            // carried as `pendingWork` so hibernation can still refuse the
            // pane, instead of the pane claiming the agent is still working.
            return (.idle, false)
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
