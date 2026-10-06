/// The pane's agent state, as the compact-and-resume flow needs to see it.
public enum AgentCompactResumeLifecycle: Sendable, Equatable {
    /// The agent is working on a turn.
    case running
    /// The agent is waiting on a dialog (a permission prompt or a question),
    /// or its state isn't known. Nothing is typed in this state: keys would
    /// answer the dialog.
    case blocked
    /// The agent is at its prompt, waiting for the next message.
    case idle
    /// No supported agent session is on the pane anymore.
    case absent
}
