import Foundation

/// Why a panel notification is being dismissed. The context decides which
/// indicator classes the dismissal may clear.
public enum NotificationDismissalContext: Sendable {
    /// Generic active focus (restore or programmatic selection included).
    case activeFocus
    /// The user explicitly resumed/selected the workspace.
    case explicitWorkspaceResume
    /// The user directly interacted with the panel (click, jump-to-unread).
    case directInteraction
    /// The user typed into the terminal.
    case terminalInteraction

    /// Whether dismissal in this context requires the app to be active.
    public var requiresActiveApp: Bool {
        switch self {
        case .activeFocus, .explicitWorkspaceResume:
            return true
        case .directInteraction, .terminalInteraction:
            return false
        }
    }

    /// Whether this context may clear a manually-set unread indicator.
    public var canDismissManualUnreadIndicator: Bool {
        self == .terminalInteraction
    }

    /// Whether this context may clear a session-restored unread indicator.
    ///
    /// Generic active focus can be produced by restore/programmatic
    /// selection. Kept exhaustive so any future context must make an
    /// explicit restored-unread policy decision.
    public var canDismissRestoredUnreadIndicator: Bool {
        switch self {
        case .activeFocus:
            return false
        case .explicitWorkspaceResume, .directInteraction, .terminalInteraction:
            return true
        }
    }
}
