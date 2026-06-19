/// Why a workspace pane is flashing for attention.
///
/// Drives the tmux pane overlay flash animation and the per-panel attention
/// ring. The raw values are stable identifiers used in debug logging; do not
/// rename cases without updating any persisted or logged references.
public enum WorkspaceAttentionFlashReason: String, Equatable, Sendable {
    /// The user navigated to the workspace.
    case navigation
    /// A terminal notification arrived in the workspace.
    case notificationArrival
    /// A terminal notification was dismissed.
    case notificationDismiss
    /// An unread indicator was dismissed.
    case unreadIndicatorDismiss
    /// A debug-triggered flash.
    case debug
}
