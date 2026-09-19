/// Lifecycle failures of a GUI-owned shell, separate from a command's exit status.
public enum GuiShellError: Error, Sendable {
    /// Another command is still executing.
    case busy
    /// The session has been closed by its owner.
    case closed
    /// A request identifier was reused with different command text.
    case invalidRequest
    /// The shell exited before reporting completion.
    case terminated
    /// The command exceeded its execution deadline.
    case timedOut
    /// The user stopped the command.
    case cancelled
}
