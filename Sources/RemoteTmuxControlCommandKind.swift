import Foundation

enum RemoteTmuxControlCommandKind: Equatable {
    case listWindows
    case capturePane(Int)
    case paneState(Int)
    case panePath(Int)
    case paneReflow(Int)
    case paneAltScreen(Int)
    case activityQuery(UUID)
    /// A per-window `refresh-client -C '@id:WxH'` — an %error reply means
    /// the server predates the form and sizing falls back session-wide.
    case perWindowSize(Int)
    /// A `list-panes` fetch of one window's REAL pane rectangles. The layout
    /// string alone is not truth: under `pane-border-status` tmux publishes
    /// the pre-title tree while the displayed panes sit one row lower and
    /// shorter, so rendering from the layout string draws every pane a row
    /// deep. The rects are.
    case paneRects(Int)
    case other
}
