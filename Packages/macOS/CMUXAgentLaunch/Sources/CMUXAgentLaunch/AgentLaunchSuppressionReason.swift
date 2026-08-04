/// A stable reason that an agent launch command was not typed.
public enum AgentLaunchSuppressionReason: Equatable, Sendable {
    /// Observation shows an agent is already running on the target surface.
    case agentAlreadyRunning
    /// A prior launch command is still pending observation on the target surface.
    case launchAlreadyPending
}
