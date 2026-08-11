public import Observation

/// Observable connectivity state for one Mac's agent GUI sync.
@MainActor
@Observable
public final class AgentConnectivityState {
    /// The current connectivity phase.
    public private(set) var phase: AgentConnectivityPhase
    /// Consecutive reconciliation failures since the last complete sync.
    public private(set) var consecutiveFailureCount: Int
    /// Latest bounded diagnostic reason, for logging rather than direct UI copy.
    public private(set) var lastFailureReason: String?

    /// Creates a connectivity state holder.
    /// - Parameter phase: The initial phase.
    public init(phase: AgentConnectivityPhase = .offline(reason: nil)) {
        self.phase = phase
        consecutiveFailureCount = 0
        lastFailureReason = nil
    }

    /// Replaces the current phase.
    /// - Parameter phase: The next phase.
    public func setPhase(_ phase: AgentConnectivityPhase) {
        self.phase = phase
    }

    func recordFailure(reason: String) {
        consecutiveFailureCount += 1
        lastFailureReason = String(reason.prefix(256))
    }

    func recordSuccessfulSync() {
        consecutiveFailureCount = 0
        lastFailureReason = nil
    }
}
