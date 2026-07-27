import CmuxSimulator

/// One immutable render update for a pane-owned Simulator agent cursor.
struct SimulatorAgentCursorPresentation: Equatable, Sendable {
    /// Monotonic identity used to cancel stale animation and dismissal tasks.
    let generation: UInt64
    /// Display-normalized point at which motion begins.
    let origin: SimulatorPoint
    /// Display-normalized action point at which motion ends.
    let destination: SimulatorPoint
    /// Duration of the matching Simulator input sequence.
    let durationMilliseconds: Int
    /// Current touch state rendered at the action point.
    let phase: SimulatorAgentCursorPhase
}
