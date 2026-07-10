/// User-visible connectivity phase for one Mac's agent GUI sync.
public enum AgentConnectivityPhase: Hashable, Sendable {
    /// The engine has a synchronized replica and live event subscription.
    case connected
    /// The engine is waiting before retrying a failed sync attempt.
    case connecting(backoffMilliseconds: Int)
    /// The engine is actively reconciling state with the Mac.
    case updating
    /// The engine is offline and may retry.
    case offline(reason: String?)
}
