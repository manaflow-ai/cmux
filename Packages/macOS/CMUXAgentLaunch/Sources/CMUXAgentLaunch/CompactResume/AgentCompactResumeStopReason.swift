/// Why a compact-and-resume run stopped without resuming the agent.
///
/// Every stop is quiet: the flow never types anything after deciding to
/// stop, so a reason only explains what the user sees in the pane.
public enum AgentCompactResumeStopReason: String, Sendable, Equatable, CaseIterable {
    /// No Claude Code or Codex session is on the pane.
    case noAgent
    /// The agent was waiting on a dialog when the run started.
    case blocked
    /// The agent's input line has text in it, which typing would change.
    case inputNotEmpty
    /// The agent's input line couldn't be read, so it may hold a draft.
    case inputUnreadable
    /// The turn didn't end, or compaction didn't finish, within the deadline.
    case timedOut
    /// The agent session left the pane mid-run.
    case agentExited
}
