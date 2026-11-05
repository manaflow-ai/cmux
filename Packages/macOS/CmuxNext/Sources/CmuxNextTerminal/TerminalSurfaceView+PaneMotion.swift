public import AppKit
public import CmuxNextDesign
import CmuxNextTerminalGeometry
import GhosttyNextKit

/// The pane's layout spring landed: the surface takes its host's area again, and the grid held while
/// it moved goes to the owner now, once, unless it is the final grid the spring's start already sent.
extension TerminalSurfaceView: PaneMotionSettling {
    public func paneMotionDidSettle() {
        endPaneMotion()
    }
}

/// A split or a close resizes the program in the terminal at the start of the pane's spring
/// (Lawrence 2026-10-23): the final grid goes to the PTY owner in the key's turn, and the surface keeps
/// its final size in the moving pane (``TerminalHostView/holdSurface(size:anchor:)``), clipped while the
/// pane is smaller and beside the terminal background while it is larger: it reflows once, not per frame.
extension TerminalSurfaceView: PaneMotionTargeting {
    public func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        // A hidden or parked terminal does no resize work (an unselected tab): shown, it sizes once
        // (`syncWindowState`, which joins a spring still under way).
        guard isShown else { return .top }
        return restAt(restSize(sizeChange: sizeChange), growing: sizeChange.height > 0.5)
    }

    /// The view joined a pane already on a layout spring (a split's new pane gets its terminal from the
    /// daemon's echo mid-spring): its final grid goes now, as at a spring's start, from the size its host
    /// will rest at. Returns whether it did.
    func joinPaneMotion() -> Bool {
        guard superview is TerminalHostView, let change = enclosingRestSizeChange else { return false }
        _ = restAt(restSize(sizeChange: change), growing: change.height > 0.5)
        return true
    }

    /// The surface's size once its pane's content area grows by `sizeChange` (measured against the area's
    /// live size): from its host's live size, never from `bounds`, which a spring already under way holds
    /// at the last rest size (``TerminalHostView/holdSurface(size:anchor:)``). A spring retargeted mid-flight
    /// (a window resize, a second Cmd-D) got the held size plus the change against the live size. A host that follows
    /// its pane through a key hold (FRAME OWNER S3) measures from its size when the hold began, as the change is.
    private func restSize(sizeChange: CGSize) -> NSSize {
        guard let host = superview as? TerminalHostView else {
            return NSSize(width: max(0, bounds.width + sizeChange.width), height: max(0, bounds.height + sizeChange.height))
        }
        let basis = host.paneMotionBasisSize
        let hostSize = CGSize(width: max(0, basis.width + sizeChange.width), height: max(0, basis.height + sizeChange.height))
        return host.surfaceSize(forHostSize: hostSize)
    }

    /// A split's, a close's or a zoom's spring: reports the grid a view of `size` points fits now (the program redraws at
    /// its final size while the pane moves, Lawrence 2026-10-23) and holds the surface at that size in its host.
    ///
    /// A key resize whose pane its host follows (cmux-ad m18) reports nothing here and holds nothing: the surface takes
    /// its pane's size in every frame (``TerminalHostView/surfaceFollowsArea``), its reflow preview re-wraps the text at
    /// each frame's grid with the cursor row in view, and the PTY gets the view's grid as it changes, coalesced
    /// (`updateSurfaceSize`), ending at the landing's grid. A hold an earlier spring or a join set goes now (review of
    /// #35470 at 447f784c3cf, G1).
    ///
    /// When it holds, a pane that grows down with the prompt in its lower half (`motionAnchor` answers `.bottom`) keeps
    /// the surface on the moving bottom edge, so the prompt on the final grid's last row stays in view.
    private func restAt(_ size: NSSize, growing: Bool) -> PaneMotionAnchor {
        guard let surface else { return .top }
        let host = superview as? TerminalHostView
        if let host, host.surfaceFollowsArea {
            host.releaseSurfaceHold()
            updateReflowPreview()
            return .top
        }
        let pixels = convertToBacking(size)
        var columns: UInt16 = 0
        var rows: UInt16 = 0
        guard pixels.width >= 1, pixels.height >= 1,
              ghostty_surface_fit_grid(surface, UInt32(pixels.width), UInt32(pixels.height), &columns, &rows)
        else { return .top }
        reportFinalGrid(TerminalGridSize(columns: Int(columns), rows: Int(rows)))
        let anchor = motionAnchor(growing: growing)
        host?.holdSurface(size: size, anchor: anchor)
        return anchor
    }

    /// The edge the terminal rides in a pane that grows down: the bottom while the cursor is in the
    /// lower half of a normal screen, because the owner pulls scrollback down as the grid grows and a
    /// prompt on the last row would be cut off for the whole spring; the top for a full-screen
    /// program (the alternate screen keeps its top-left origin) or a cursor near the top.
    private func motionAnchor(growing: Bool) -> PaneMotionAnchor {
        guard growing, let surface else { return .top }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport, !metrics.alternate_screen,
              metrics.rows > 0 else { return .top }
        return Int(metrics.cursor_row) * 2 >= Int(metrics.rows) ? .bottom : .top
    }
}

/// A person's divider or edge drag (`ScreenContentView+ResizeGesture`): the pane follows the pointer with no
/// spring, so without this the terminal reported a grid on every drag event and its program redrew at each
/// size while the owner's announcements came a round trip behind the view (torn rows mid-drag). Through the
/// drag the surface keeps its size and its text (no report, no reflow); when the drag and its release's spring
/// landed, the grid the view fits goes to the PTY once (none when the release's spring already sent it at its
/// start, `restAt`).
extension TerminalSurfaceView: PaneResizeGestureFollowing {
    public func paneResizeGestureDidChange(active: Bool) {
        guard isFollowingResizeGesture != active else { return }
        isFollowingResizeGesture = active
        if active, TerminalDragTunables.holdsSurfaceDuringDrag.value {
            // The text stays where it is through the drag (RESIZE VIDEOS A3: drawn reflowed to the pane on every drag
            // frame, the wrap point moved in every frame): the surface keeps its size, clipped where the pane is
            // narrower and beside the terminal background where it is wider, as a Chromium page does.
            (superview as? TerminalHostView)?.holdSurface(size: bounds.size, anchor: .top)
            return
        }
        guard !active else { return }
        // A release that springs moved the hold to its final size at the spring's start (`restAt`) and let it go when
        // it landed; one that did not spring lets go here: the surface takes its pane's size and reflows once.
        if !isInPaneMotion { (superview as? TerminalHostView)?.releaseSurfaceHold() }
        if isHeldGridPending { updateSurfaceSize() }
    }
}
