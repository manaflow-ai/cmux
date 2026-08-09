import Foundation

enum RemoteTmuxControlCommandKind: Equatable {
    /// A topology snapshot tagged with the accepted reorder generation and the
    /// exact close-gap pane identities it may release when the reply succeeds.
    case listWindows(reorderGeneration: UInt64, retainedPaneIDs: Set<Int>)
    /// An order-only snapshot used to verify a successful swap batch cheaply.
    case listWindowOrder(reorderGeneration: UInt64)
    case paneOutputReset(Int, UUID)
    case paneOutputContinue(Int, UUID)
    case capturePane(Int, UUID)
    case paneState(Int, UUID)
    case panePath(Int)
    case paneReflow(Int)
    case paneAltScreen(Int, UUID)
    case activityQuery(UUID)
    case newWindow(UUID)
    /// A focused `split-window -P -F '#{pane_id}'` whose stable created-pane
    /// identity is delivered to the owner of the pending focus handoff.
    case newPane(UUID)
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
    /// A command whose raw reply lines the sender awaits (see
    /// ``RemoteTmuxControlConnection/queryOutcomeWithTimeout(_:timeout:reconnectOnTimeout:)``):
    /// the token keys a completion fired with the `%end` reply lines, the `%error`
    /// text, or `.unanswered` on a timeout or a stream reset before the block arrives.
    case rawQuery(UUID)
    case other
}

/// How a raw-line query ended.
enum RemoteTmuxRawQueryOutcome {
    /// The command's `%end` block, which may legitimately be empty.
    case lines([String])
    /// The server rejected the command and sent `%error` with this text.
    case error([String])
    /// No reply arrived before the timeout, or the stream reset first.
    case unanswered

    var lines: [String]? {
        if case let .lines(lines) = self { return lines }
        return nil
    }
}
