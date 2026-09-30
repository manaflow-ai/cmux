import CmuxNextDaemon

/// Deadlines of a request that waits for cmux-tui to start a terminal
/// (architecture.md 5a). One budget end to end: the daemon command's own
/// deadline, and the control request's, which adds 1 s for the main-actor
/// work queue and the compat layer's tree diff so the daemon command
/// answers or fails before the request does.
enum TerminalStartDeadline {
    /// `DaemonConnection.defaultSpawnTimeout`.
    static let daemon: Duration = DaemonConnection.defaultSpawnTimeout
    static let request: Duration = daemon + .seconds(1)
}
