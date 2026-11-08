import CmuxRemoteSession
/// A parsed remote-tmux layout awaiting authoritative pane rectangles.
///
/// Tmux publishes pre-title geometry in its layout string when pane headers
/// are enabled, so the connection quarantines this value until `list-panes`
/// supplies the display rectangles that are safe to publish.
struct RemoteTmuxPendingLayout {
    var node: RemoteTmuxLayoutNode
    var visibleNode: RemoteTmuxLayoutNode?
    var zoomed: Bool
    var name: String
    /// Bumped per stored layout so stale rectangle replies can be discarded.
    var generation: Int
    /// Whether a newer layout arrived while a rectangle fetch was in flight.
    var dirty = false
    var inFlight = false
    var retriesRemaining = 1
}
