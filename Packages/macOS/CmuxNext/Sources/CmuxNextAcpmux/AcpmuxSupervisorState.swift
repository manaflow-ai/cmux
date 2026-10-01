/// What the app's acpmux daemon is doing.
public enum AcpmuxSupervisorState: Sendable, Equatable {
    /// Not started, or stopped by the app.
    case stopped
    /// Launching (acpmux imports the login environment first).
    case starting
    /// Serving on its socket.
    case running(pid: Int32)
    /// It exited or failed to start; a restart follows after a backoff.
    case failed(reason: String)
    /// No acpmux binary is bundled (and no override is set).
    case unavailable
}
