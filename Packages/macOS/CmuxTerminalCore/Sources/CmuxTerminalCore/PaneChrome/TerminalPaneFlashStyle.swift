public import CmuxCore

/// Which attention animation a terminal pane's flash overlay should present.
///
/// This is the surface-model-facing value that selects between the two flash
/// presentations. It carries no AppKit color or metric: the app target resolves
/// the concrete stroke color, glow, and ring geometry into a
/// ``TerminalPaneRingPresentation`` and pushes both to the overlay container, so
/// the view layer never reaches back into app-target presentation types.
public enum TerminalPaneFlashStyle: Sendable, Equatable {
    /// A focus/navigation flash (pane gained focus or was navigated to).
    case navigation
    /// A notification flash (a notification arrived or was dismissed).
    case notification

    /// Selects the flash style for an attention reason: navigation flashes for
    /// ``WorkspaceAttentionFlashReason/navigation`` and notification flashes for
    /// every notification/indicator/debug reason.
    public init(reason: WorkspaceAttentionFlashReason) {
        switch reason {
        case .navigation:
            self = .navigation
        case .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            self = .notification
        }
    }
}
