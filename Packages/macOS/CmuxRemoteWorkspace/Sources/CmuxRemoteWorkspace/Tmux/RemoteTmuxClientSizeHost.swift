/// Read/write seam that ``RemoteTmuxClientSizeController`` uses to drive its owning
/// `tmux -CC` control connection without referencing the app-only mirror topology
/// types (windows/panes). The connection conforms and injects itself via
/// ``RemoteTmuxClientSizeController/attach(host:)``.
///
/// Every member is plain (`Int` sizes, `Bool` checks, `String` commands), so the
/// client-size + attach-redraw-kick sub-model lives in this package while the
/// window/pane geometry it consults stays app-side.
@MainActor
public protocol RemoteTmuxClientSizeHost: AnyObject {
    /// `true` while control mode is live (`.connected`); a size send only goes out
    /// then, otherwise it would silently drop onto dead stdin.
    var isClientSizeConnectionConnected: Bool { get }

    /// `true` once the mirror topology has at least one window drained, so a redraw
    /// kick has a window whose size it can compare against.
    var hasMirroredWindowTopology: Bool { get }

    /// Whether some mirrored window already has exactly this grid, i.e. the size
    /// apply cannot itself produce a SIGWINCH for it (the redraw-kick precondition).
    func mirroredWindowMatchesClientSize(columns: Int, rows: Int) -> Bool

    /// Writes one tmux control command (`refresh-client -C …`) over the live stdin.
    func sendClientSizeCommand(_ command: String)

    /// Clears a deferred `.applyClientSize` post-attach action once a live debounced
    /// size send has already applied the stored grid (so the deferred apply is not
    /// duplicated).
    func clientSizeApplyDidCoverPendingPostAttachAction()

    /// DEBUG-only redraw-kick diagnostics, routed app-side so the package never binds
    /// the app's `cmuxDebugLog`. The message autoclosure is evaluated only in DEBUG
    /// builds.
    func logClientSizeEvent(_ message: @autoclosure () -> String)
}
