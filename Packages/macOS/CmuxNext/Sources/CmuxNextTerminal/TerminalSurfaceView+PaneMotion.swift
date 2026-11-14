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
        // A drag's release spring (cmux-ad m14): no hold at the final size; the surface keeps following its pane, and the
        // grid goes once, when the release lands (``followResizeGesture(_:)``).
        guard !isFollowingResizeGesture else { return .top }
        return restAt(restSize(sizeChange: sizeChange))
    }

    /// The view joined a pane already on a layout spring (a split's new pane gets its terminal from the
    /// daemon's echo mid-spring): its final grid goes now, as at a spring's start, from the size its host
    /// will rest at. Returns whether it did (never for a drag's release spring: its grid goes at the landing).
    func joinPaneMotion() -> Bool {
        guard !isFollowingResizeGesture, superview is TerminalHostView, let change = enclosingRestSizeChange else { return false }
        _ = restAt(restSize(sizeChange: change))
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
    /// When it holds, the surface rides the edge its text keeps in Ghostty's reflow to the final grid (`motionAnchor`), so
    /// each row moves from where it shows now straight to where it rests, never away from it.
    private func restAt(_ size: NSSize) -> PaneMotionAnchor {
        guard let surface else { return .top }
        let host = superview as? TerminalHostView
        // A tab shown mid-hold joins before its area hands it the follow: it follows from its first frame too, so its
        // grid goes through the coalescer, never as a final grid beside the coalesced ones.
        if let host, host.surfaceFollowsArea || host.joinsAreaKeyHold {
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
        // Read before the report: the owner's resize to the final grid can land in this call, and the edge is the one
        // the text keeps from the rows it shows now.
        let anchor = motionAnchor(finalRows: Int(rows))
        reportFinalGrid(TerminalGridSize(columns: Int(columns), rows: Int(rows)))
        host?.holdSurface(size: size, anchor: anchor)
        return anchor
    }

    /// The edge the terminal's text keeps when Ghostty resizes its grid to `finalRows` (`PageList.resizeWithoutReflow`), the
    /// edge the held surface rides so no row moves away from its rest (Leo 2026-11-06: a close "goes all the way down and
    /// then back up ... if it's at the top, it doesn't").
    /// - More rows: Ghostty pulls scrollback down only when the cursor is on the last row; otherwise the new rows are blank
    ///   ones under the text, which keeps its top. Before, any cursor in the lower half
    ///   rode the bottom edge: a prompt above the last row with no history to pull showed its text a whole growth above its
    ///   place at the spring's first frame, then slid back down.
    /// - Fewer rows: Ghostty trims the blank rows under the cursor first; only the rest go into the history, moving the
    ///   text up with the bottom edge.
    /// The bottom when the rows that move are at least half the change, else the top. The alternate screen keeps its top.
    private func motionAnchor(finalRows: Int) -> PaneMotionAnchor {
        guard let surface else { return .top }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport, !metrics.alternate_screen,
              metrics.rows > 0 else { return .top }
        let rows = Int(metrics.rows), cursor = Int(metrics.cursor_row)
        let change = abs(finalRows - rows)
        guard change > 0 else { return .top }
        // A cursor on the last row has scrolled output into the history, which Ghostty pulls down (the scrollbar report
        // that would count it lags the output, so it is not read here).
        if finalRows > rows { return cursor >= rows - 1 ? .bottom : .top }
        let moved = max(0, change - max(0, rows - 1 - cursor))
        return moved * 2 >= change ? .bottom : .top
    }
}

/// A person's divider or edge drag (`ScreenContentView+ResizeGesture`, told to the surface by its host,
/// ``TerminalHostView/paneResizeGestureDidChange(active:)``): the pane follows the pointer with no spring. cmux-ad m14
/// (Lawrence's P0): in every frame of the drag and of its release each terminal shows its text at that frame's pane size,
/// never frozen or anchored. The surface takes its pane's size in every frame through the placement
/// any resize uses (`TerminalHostView` `placeSurface`, the frame owner's ``place(_:anchor:)``), and the reflow preview
/// re-wraps its text at that size. The program gets its size while it moves, at most once per refresh (cmux-ad m29,
/// RESIZE P0 6: ``TerminalGridReporter``), and the newest at the release (a full-screen program froze with one grid). Before, the drag hold
/// (`terminalDrag.holdSurface`, RESIZE VIDEOS A3) kept the drag-start size and text through the drag, and the release's
/// spring held its final size (pixel-perfect's trace, STATUS 13764: 157-159 held ticks in col-drag-2, the surface up to
/// 150 pt off its pane).
extension TerminalSurfaceView {
    func followResizeGesture(_ active: Bool) {
        guard isFollowingResizeGesture != active else { return }
        isFollowingResizeGesture = active
        // The start ends a spring's hold the drag caught (a split or a press still landing): the surface follows the drag
        // from this frame. The end sends the grid that waits in the coalescer's window now, then any grid still held.
        if active { endPaneMotion() } else {
            resendShownGrid(atRest: true)
            gridReports.flush()
            if isHeldGridPending { updateSurfaceSize() }
        }
    }

    /// A grid the PTY lacks was dropped with a hide (``cancelGridReport()``): shown, the view's grid goes once (nothing
    /// when the PTY has it). `atRest`, now. In a key spring or a drag (the surface follows its pane), coalesced with that
    /// motion's grids, so the window's end or the landing sends it. In a split's, close's or zoom's spring it waits for
    /// the landing (``endPaneMotion()``), as the grid such a spring holds. Review of 5840aea3a603, P1 #2: a show inside a
    /// key spring dropped it, the geometry already counted it as sent, and the PTY kept the older grid after the landing.
    func resendShownGrid(atRest: Bool) {
        guard resendsShownGrid, isShown else { return }
        guard ownsGeometry, let grid = fittedGrid else {
            resendsShownGrid = false
            return
        }
        let live = isFollowingResizeGesture || ((superview as? TerminalHostView)?.surfaceFollowsArea ?? false)
        guard atRest || live else { return }
        resendsShownGrid = false
        gridReports.coalesced(grid)
        if atRest { gridReports.flush() }
    }
}
