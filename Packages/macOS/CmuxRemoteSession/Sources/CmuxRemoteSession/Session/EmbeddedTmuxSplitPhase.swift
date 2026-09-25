/// The result of the most recent split inside a terminal-attached tmux session.
public enum EmbeddedTmuxSplitPhase: String, Sendable {
    /// No request has been submitted in this connection lifetime.
    case idle
    /// A single SSH management command is in flight.
    case running
    /// tmux confirmed creation of a remote pane.
    case succeeded
    /// The command failed or its outcome could not be confirmed; it is never retried automatically.
    case failed
}
