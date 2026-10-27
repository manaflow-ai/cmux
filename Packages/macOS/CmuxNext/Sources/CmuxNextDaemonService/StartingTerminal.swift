import CmuxNextDaemon

/// The reply of a command that makes a terminal tab, and the watch of its terminal's start when the
/// daemon answers before the host is up (`terminal-async-start-v1`, ``TerminalStartWatch``): the
/// reply settles the command's intent, and ``started(cancelled:)`` carries the start's outcome to the
/// action that made it (``NewTerminalTabCommand``, ``PaneSplitCommand``).
struct StartingTerminal: Sendable {
    /// The command's reply.
    let created: SurfaceCreated
    /// The watch of its terminal's start, opened before the command went out (the start can end
    /// right after the reply); nil when the daemon answers after the start.
    let watch: TerminalStartWatch?

    /// Waits for the terminal's start. Returns the reply once it started (or when the connection
    /// dropped first: the next snapshot shows the terminal or not); throws ``TerminalStartFailure``
    /// when it did not start (the daemon rolls back what the command made) and `cancelled` when the
    /// tab closed first.
    ///
    /// - Parameter cancelled: The command's own error for a tab closed before the start ended.
    func started(cancelled: @autoclosure () -> any Error) async throws -> SurfaceCreated {
        switch await watch?.outcome(of: created) ?? .started {
        case .started, .unknown: return created
        case .failed(let failure): throw failure
        case .closed: throw cancelled()
        }
    }
}
