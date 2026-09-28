import CMUXAgentLaunch

/// The answer to a compact-and-resume request on a pane.
enum AgentCompactResumeStart: Equatable, Sendable {
    /// The run started for this agent and continues on its own.
    case started(AgentTurnInterruptTarget)
    /// A run is already in progress on the pane.
    case alreadyRunning
    /// The run stopped before typing anything.
    case refused(AgentCompactResumeStopReason)
}
