import Foundation

enum RemoteTmuxControlCommandKind: Equatable {
    /// A topology snapshot tagged with the accepted reorder generation and the
    /// exact close-gap pane identities it may release when the reply succeeds.
    case listWindows(reorderGeneration: UInt64, retainedPaneIDs: Set<Int>)
    /// An order-only snapshot used to verify a successful swap batch cheaply.
    case listWindowOrder(reorderGeneration: UInt64)
    case capturePane(Int)
    case paneState(Int)
    case panePath(Int)
    case paneReflow(Int)
    case paneAltScreen(Int)
    case activityQuery(UUID)
    case newWindow(UUID)
    /// A per-window `refresh-client -C '@id:WxH'` — an %error reply means
    /// the server predates the form and sizing falls back session-wide.
    case perWindowSize(Int)
    /// A `list-panes` fetch of one window's REAL pane rectangles, tagged
    /// with the pending-layout generation it publishes. The layout string
    /// alone is not truth: under `pane-border-status` tmux publishes the
    /// pre-title tree while panes touching the configured edge are one row
    /// shorter (and top-edge panes also sit one row lower). The rects are;
    /// a reply whose generation is stale is discarded.
    case paneRects(Int, Int)
    /// One command in an atomically-enqueued `swap-window` mirror reorder.
    case windowReorder(isLast: Bool)
    /// A command whose block resolution the sender observes (see
    /// ``RemoteTmuxControlConnection/sendTracked(_:completion:)``): the token
    /// keys a completion that fires `true` on `%end`, `false` on `%error` or
    /// when the stream resets before the block arrives.
    case tracked(UUID)
    case other
}
