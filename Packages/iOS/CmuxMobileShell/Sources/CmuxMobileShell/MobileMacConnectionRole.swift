/// The highest-priority capability shown for a live Mac session.
public enum MobileMacConnectionRole: Equatable, Sendable {
    /// Carries aggregate workspace, presence-adjacent state, notification, and
    /// command traffic.
    case control
    /// Carries control traffic plus the focused terminal's render stream.
    case focused
}
