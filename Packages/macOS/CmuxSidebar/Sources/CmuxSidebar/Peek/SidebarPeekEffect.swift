/// A timer the peek machine wants started or stopped.
///
/// Returned by the machine instead of being scheduled inside it, so the state
/// transitions stay pure and the timing policy stays testable without a clock.
public enum SidebarPeekEffect: Sendable, Hashable {
    /// Start (or restart) the dwell timer before revealing.
    case startDwellTimer
    /// Stop the dwell timer.
    case cancelDwellTimer
    /// Start (or restart) the grace timer before dismissing.
    case startGraceTimer
    /// Stop the grace timer.
    case cancelGraceTimer
}
