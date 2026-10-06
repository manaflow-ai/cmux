/// When a compact-and-resume run may cut into the agent's current turn.
public enum AgentCompactResumeTiming: String, Sendable, Equatable, CaseIterable {
    /// Interrupt a running turn first, then compact. The default for a click,
    /// where the user is asking for it right away.
    case now
    /// Wait for the running turn to end on its own, so no tool call is cut
    /// off. The default for the CLI, which an agent may run on its own pane.
    case idle
}
