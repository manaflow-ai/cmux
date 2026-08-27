/// Accumulated reducer state: per-surface, per-agent, per-session lifecycle.
///
/// Keys are the identity strings recorded on the events themselves (the
/// runtime UUIDs at emit time); alias resolution to the current runtime
/// identity happens in the projection layer, not here, so the fold stays a
/// pure function of the event stream.
public struct AgentLifecycleReducerState: Sendable, Equatable {
    /// `surfaceId → agentKey → sessionKey → state`.
    public private(set) var sessions: [String: [String: [String: AgentSessionLifecycleState]]]
    /// Unattributed diagnostic events seen by the fold (bounded).
    public private(set) var unattributedEvents: [AgentJournalEvent]
    /// Highest sequence this state has folded.
    public private(set) var headSequence: Int64

    /// Bound on retained unattributed diagnostics.
    public static let maximumRetainedUnattributedEvents = 256

    /// Creates an empty state.
    public init() {
        self.sessions = [:]
        self.unattributedEvents = []
        self.headSequence = 0
    }

    /// The session key an event folds into: the native session id when the
    /// adapter provides one, otherwise a per-source singleton bucket.
    ///
    /// - Parameter draft: The event's draft.
    /// - Returns: The session key.
    public static func sessionKey(for draft: AgentJournalEventDraft) -> String {
        if let sessionId = draft.sessionId, !sessionId.isEmpty {
            return sessionId
        }
        return "@\(draft.source)"
    }

    /// Whether a draft asserts a phase for the whole pane rather than for one
    /// session.
    ///
    /// A declared phase with no session id comes from a corrector that read the
    /// pane's screen, and a screen has no session: it is saying "whatever is
    /// running in this pane, it is in this phase now". Such an event applies to
    /// every live session on the surface instead of opening a bucket beside
    /// them — the correction has to be able to move the session it corrects,
    /// and ``AgentLifecyclePhase/combinePrecedence`` ranks `running` above
    /// every phase a corrector can declare.
    ///
    /// - Parameter draft: The event's draft.
    /// - Returns: `true` when the draft is a whole-pane assertion.
    public static func isPaneLevelAssertion(_ draft: AgentJournalEventDraft) -> Bool {
        draft.kind == .stateChanged
            && draft.declaredPhase != nil
            && (draft.sessionId?.isEmpty ?? true)
    }

    /// Combined phase for one surface/agent pair across its live sessions,
    /// or `nil` when every session has ended (the sidebar entry clears).
    ///
    /// - Parameters:
    ///   - surfaceId: The surface UUID string as recorded on events.
    ///   - agentKey: The sidebar lifecycle status key.
    /// - Returns: The combined phase, or `nil`.
    public func combinedPhase(surfaceId: String, agentKey: String) -> AgentLifecyclePhase? {
        guard let bySession = sessions[surfaceId]?[agentKey] else { return nil }
        let live = bySession.values.filter { !$0.ended }
        return live.map(\.phase).max { $0.combinePrecedence < $1.combinePrecedence }
    }

    /// Whether any live session for this agent on this surface still has
    /// outstanding background work.
    ///
    /// - Parameters:
    ///   - surfaceId: The surface.
    ///   - agentKey: The agent key.
    /// - Returns: `true` when at least one live session reported pending work.
    public func combinedPendingWork(surfaceId: String, agentKey: String) -> Bool {
        guard let bySession = sessions[surfaceId]?[agentKey] else { return false }
        return bySession.values.contains { !$0.ended && $0.pendingWork }
    }

    /// Full combined snapshot across all surfaces and agents.
    ///
    /// - Returns: The snapshot the projection layer diffs and applies.
    public func snapshot() -> AgentLifecycleSnapshot {
        var phases: [String: [String: AgentLifecyclePhase]] = [:]
        var newestOccurredAtMs: [String: [String: Int64]] = [:]
        var pendingWork: [String: [String: Bool]] = [:]
        for (surfaceId, byAgent) in sessions {
            for (agentKey, bySession) in byAgent {
                let live = bySession.values.filter { !$0.ended }
                guard let phase = live.map(\.phase).max(by: {
                    $0.combinePrecedence < $1.combinePrecedence
                }) else { continue }
                phases[surfaceId, default: [:]][agentKey] = phase
                newestOccurredAtMs[surfaceId, default: [:]][agentKey] =
                    live.map(\.lastOccurredAtMs).max() ?? 0
                if live.contains(where: \.pendingWork) {
                    pendingWork[surfaceId, default: [:]][agentKey] = true
                }
            }
        }
        return AgentLifecycleSnapshot(
            phases: phases,
            newestOccurredAtMs: newestOccurredAtMs,
            pendingWork: pendingWork
        )
    }

    mutating func recordUnattributed(_ event: AgentJournalEvent) {
        unattributedEvents.append(event)
        if unattributedEvents.count > Self.maximumRetainedUnattributedEvents {
            unattributedEvents.removeFirst(
                unattributedEvents.count - Self.maximumRetainedUnattributedEvents
            )
        }
    }

    mutating func advanceHead(to sequence: Int64) {
        headSequence = max(headSequence, sequence)
    }

    mutating func updateSession(
        surfaceId: String,
        agentKey: String,
        sessionKey: String,
        state: AgentSessionLifecycleState
    ) {
        sessions[surfaceId, default: [:]][agentKey, default: [:]][sessionKey] = state
    }

    func session(
        surfaceId: String,
        agentKey: String,
        sessionKey: String
    ) -> AgentSessionLifecycleState? {
        sessions[surfaceId]?[agentKey]?[sessionKey]
    }

    /// Keys of every session for this surface/agent that has not ended, sorted
    /// so the fold visits them in a stable order.
    ///
    /// - Parameters:
    ///   - surfaceId: The surface.
    ///   - agentKey: The agent key.
    /// - Returns: The live session keys.
    func liveSessionKeys(surfaceId: String, agentKey: String) -> [String] {
        guard let bySession = sessions[surfaceId]?[agentKey] else { return [] }
        return bySession.compactMap { $0.value.ended ? nil : $0.key }.sorted()
    }
}
