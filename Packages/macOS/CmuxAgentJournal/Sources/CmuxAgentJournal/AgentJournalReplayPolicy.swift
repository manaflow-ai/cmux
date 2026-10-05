/// What startup replay is allowed to paint.
///
/// Replay reproduces badges from the journal instead of trusting the last
/// painted state, but it must not claim liveness the journal cannot prove
/// after a relaunch:
///
/// - `needsInput` and `error` survive replay: the agent was blocked on the
///   user, and that fact stays true across an app restart (the stale-badge
///   bug class this design fixes).
/// - `running` is downgraded out: a relaunch tore down local PTYs, so a
///   journal-running agent is usually dead; the next live event restores the
///   spinner honestly.
/// - `idle` and `unknown` are dropped: painting them adds no user signal and
///   `idle` would re-enter hibernation eligibility for panes whose agent is
///   not actually alive.
public struct AgentJournalReplayPolicy: Sendable {
    /// Creates a policy.
    public init() {}

    /// Retains blocked activity and independent metadata without replaying historical liveness.
    /// - Parameter state: One reduced native session, with its original evidence timestamps.
    /// - Returns: Session evidence safe to apply after startup; mode and exact requests are unchanged.
    public func startupRuntimeState(from state: AgentSessionLifecycleState) -> AgentSessionLifecycleState {
        var startup = state
        switch state.activity {
        case .needsInput, .failed, .quotaBlocked:
            break
        case .unknown, .working, .idle, .ready, .waiting, .paused, .ended:
            startup.phase = .unknown
            startup.ended = false
            startup.activity = .unknown
            startup.reason = nil
            startup.activityObservedAtMs = nil
            startup.transitionedAtMs = nil
            startup.processGeneration = nil
        }
        return startup
    }

    /// Filters a reduced snapshot down to what startup replay may paint.
    ///
    /// - Parameter snapshot: The full reduced snapshot.
    /// - Returns: The startup-safe snapshot.
    public func startupSnapshot(from snapshot: AgentLifecycleSnapshot) -> AgentLifecycleSnapshot {
        var phases: [String: [String: AgentLifecyclePhase]] = [:]
        var newest: [String: [String: Int64]] = [:]
        for (surfaceId, byAgent) in snapshot.phases {
            for (agentKey, phase) in byAgent {
                switch phase {
                case .needsInput, .error:
                    phases[surfaceId, default: [:]][agentKey] = phase
                    newest[surfaceId, default: [:]][agentKey] =
                        snapshot.newestOccurredAtMs[surfaceId]?[agentKey] ?? 0
                case .running, .backgroundWorkPending, .idle, .unknown:
                    continue
                }
            }
        }
        return AgentLifecycleSnapshot(phases: phases, newestOccurredAtMs: newest)
    }
}
