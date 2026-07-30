/// Visual phase for one workspace-contained Simulator agent cursor.
enum SimulatorAgentCursorPhase: Equatable, Sendable {
    /// The persistent cursor is idle between programmatic actions.
    case resting
    /// A programmatic touch is currently down.
    case pressed
    /// A programmatic touch completed successfully.
    case clicked
    /// A programmatic touch failed or was cancelled.
    case cancelled
}
