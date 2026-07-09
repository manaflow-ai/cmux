/// Why the app is currently suppressing a window move, so the suppression
/// sequence can be keyed and reported back to the routing layer.
///
/// A pure value type. The raw values feed debug breadcrumbs and log lines, so
/// they must stay stable. Faithful lift of the app-target
/// `WindowMoveSuppressionReason`.
public enum WindowMoveSuppressionReason: String {
    /// A proxy-folder-icon drag is in progress; the window must not move with it.
    case folderDrag
    /// A Bonsplit pane-tab drag is in progress; the window must not move with it.
    case bonsplitPaneTabDrag
}
