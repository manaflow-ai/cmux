public import Observation

/// Observable connectivity state for one Mac's agent GUI sync.
@MainActor
@Observable
public final class AgentConnectivityState {
    /// The current connectivity phase.
    public private(set) var phase: AgentConnectivityPhase

    /// Creates a connectivity state holder.
    /// - Parameter phase: The initial phase.
    public init(phase: AgentConnectivityPhase = .offline(reason: nil)) {
        self.phase = phase
    }

    /// Replaces the current phase.
    /// - Parameter phase: The next phase.
    public func setPhase(_ phase: AgentConnectivityPhase) {
        self.phase = phase
    }
}
