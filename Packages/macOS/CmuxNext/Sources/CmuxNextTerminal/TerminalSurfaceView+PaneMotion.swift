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
    /// (a window resize, a second Cmd-D) got the held size plus the change against the live size.
    private func restSize(sizeChange: CGSize) -> NSSize {
        guard let host = superview as? TerminalHostView else {
            return NSSize(width: max(0, bounds.width + sizeChange.width), height: max(0, bounds.height + sizeChange.height))
        }
        let hostSize = CGSize(width: max(0, host.bounds.width + sizeChange.width),
                              height: max(0, host.bounds.height + sizeChange.height))
        return host.surfaceSize(forHostSize: hostSize)
    }

    /// Reports the grid a view of `size` points fits and holds the surface at that size in its host.
    private func restAt(_ size: NSSize, growing: Bool) -> PaneMotionAnchor {
        guard let surface else { return .top }
        let pixels = convertToBacking(size)
        var columns: UInt16 = 0
        var rows: UInt16 = 0
        guard pixels.width >= 1, pixels.height >= 1,
              ghostty_surface_fit_grid(surface, UInt32(pixels.width), UInt32(pixels.height), &columns, &rows)
        else { return .top }
        reportFinalGrid(TerminalGridSize(columns: Int(columns), rows: Int(rows)))
        let anchor = motionAnchor(growing: growing)
        (superview as? TerminalHostView)?.holdSurface(size: size, anchor: anchor)
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
