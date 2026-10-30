public import CmuxNextWakeups

/// When a ``LaunchStart`` runs.
public enum LaunchStartClass: Sendable, Equatable {
    /// In the launch turn, a direct call: the first frame needs it.
    case firstFrame
    /// A ``StartupPriority/afterStartup`` post: the background class, open from the reveal, released
    /// once startup completes.
    case afterReveal

    /// The priority of its post; nil for a start the launch turn calls directly.
    public var priority: StartupPriority? {
        switch self {
        case .firstFrame: nil
        case .afterReveal: .afterStartup
        }
    }
}
