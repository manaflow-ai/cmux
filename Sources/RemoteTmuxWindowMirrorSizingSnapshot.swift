import AppKit
import CmuxRemoteWorkspace
import CmuxTerminal

/// Per-window sizing introspection returned by
/// ``RemoteTmuxWindowMirror/sizingSnapshot()`` and serialized by the
/// `remote.tmux.pane_grids` socket command: each pane's tmux-assigned dims (the
/// window's base layout node) next to the grid its ghostty surface actually
/// renders, plus the sizing state around them.
///
/// Top-level and `Sendable` (not nested in the `@MainActor` mirror) so socket
/// handlers can carry it off the main actor after a `MainActor.run` read —
/// the same shape as ``RemoteTmuxControlConnectionSnapshot``.
struct RemoteTmuxWindowMirrorSizingSnapshot: Sendable {
    struct Pane: Sendable {
        let paneId: Int
        let assignedCols: Int
        let assignedRows: Int
        let renderedCols: Int?
        let renderedRows: Int?
        /// Which axes the render contract requires to be EXACT (the leaf's
        /// enclosing split axes). The other axis fills its parent, so the
        /// surface may legitimately render beyond the assignment there.
        let exactCols: Bool
        let exactRows: Bool
        /// Why a rendered grid might be absent: whether the pane still has a
        /// panel at all, whether its view sits in a window, and whether the
        /// runtime surface is live.
        let hasPanel: Bool
        let viewInWindow: Bool?
        let surfaceLive: Bool?
        /// Raw device-pixel calibration sample (see
        /// ``TerminalSurfaceRawSizingSample``) — the frame→grid ground truth a
        /// harness fits rendering constants against.
        let calibration: TerminalSurfaceRawSizingSample?
    }

    let windowId: Int
    let panes: [Pane]
    /// The base tree's total assigned cells (tmux's current window size).
    let baseCols: Int
    let baseRows: Int
    /// The last per-window size cmux requested (nil before the first push).
    let pushedColumns: Int?
    let pushedRows: Int?
    let zoomed: Bool
    let structureVersion: Int
    /// Sizing-input introspection: whether this mirror may push (its tab is
    /// visible), the container it last measured, and what the client-size
    /// function computes from that container right now — lets a harness
    /// distinguish "push gate closed" from "push stale" from "geometry
    /// unknown" without screenshots.
    let visibleForSizing: Bool
    let containerPt: CGSize?
    let currentFCols: Int?
    let currentFRows: Int?
}
