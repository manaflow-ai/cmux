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
        let size = NSSize(width: max(0, bounds.width + sizeChange.width), height: max(0, bounds.height + sizeChange.height))
        return restAt(size, growing: sizeChange.height > 0.5)
    }

    /// The view joined a pane already on a layout spring (a split's new pane gets its terminal from the
    /// daemon's echo mid-spring): its final grid goes now, as at a spring's start, from the size its host
    /// will rest at. Returns whether it did.
    func joinPaneMotion() -> Bool {
        guard let host = superview as? TerminalHostView, let change = enclosingRestSizeChange else { return false }
        let hostSize = CGSize(width: max(0, host.bounds.width + change.width), height: max(0, host.bounds.height + change.height))
        _ = restAt(host.surfaceSize(forHostSize: hostSize), growing: change.height > 0.5)
        return true
    }

    /// Reports the grid a view of `size` points fits and holds the surface at that size in its host.
    private func restAt(_ size: NSSize, growing: Bool) -> PaneMotionAnchor {
        guard let surface else { return .top }
        let pixels = convertToBacking(size)
        var columns: UInt16 = 0
        var rows: UInt16 = 0
        // SAFETY: the view's live surface (TerminalSurfaceView.surface); Ghostty writes one UInt16
        // into each local, alive for the call.
        guard pixels.width >= 1, pixels.height >= 1,
              unsafe ghostty_surface_fit_grid(surface, UInt32(pixels.width), UInt32(pixels.height), &columns, &rows)
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
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        guard let metrics = unsafe GhosttyTextRead.gridMetrics(surface), metrics.cursor_in_viewport, !metrics.alternate_screen,
              metrics.rows > 0 else { return .top }
        return Int(metrics.cursor_row) * 2 >= Int(metrics.rows) ? .bottom : .top
    }
}

/// The resting-grid invariant (G2, `InputInvariantMonitor.terminalGrids`; principled-audit R3).
extension TerminalSurfaceView {
    /// Nil when this terminal keeps the invariant or is not at rest; else what differs. Facts only, no timing (R5):
    /// - a terminal its pane shows on screen counts as shown (``isShown``): only a shown surface sizes itself;
    /// - shown and at rest (no pane spring, no report held): the surface was sized to the grid its bounds fit,
    ///   and, where this view sets the grid, that grid is the one it reported to the owner;
    /// - where the owner applies this view's grid (``TerminalIO/appliesViewGrid(reporting:)``: no other client
    ///   holds it, the link is up), the owner's announced grid is that grid too, once the owner answered.
    /// `onScreen`: the caller's fact that the pane shows this terminal in a visible window. `ownerSettled`: the
    /// caller's fact that no grid of this terminal waits to be sent to its owner or for the owner's echo.
    package func restingGridMismatch(onScreen: Bool, ownerSettled: Bool) -> String? {
        guard let surface else { return nil }
        guard isShown else { return onScreen ? "on screen but not shown: \(nodeChain.joined(separator: " < "))" : nil }
        guard !isInPaneMotion, !geometry.held else { return nil }
        let pixels = convertToBacking(bounds.size)
        var columns: UInt16 = 0, rows: UInt16 = 0
        // SAFETY: the view's live surface (`surface`); Ghostty writes one UInt16 into each local, alive for the call.
        guard pixels.width >= 1, pixels.height >= 1,
              unsafe ghostty_surface_fit_grid(surface, UInt32(pixels.width), UInt32(pixels.height), &columns, &rows) else { return nil }
        let fits = TerminalGridSize(columns: Int(columns), rows: Int(rows))
        let sized = geometry.desired, reported = geometry.reported, owner = geometry.announced
        func text(_ grid: TerminalGridSize?) -> String { grid.map { "\($0.columns)x\($0.rows)" } ?? "-" }
        let detail = "bounds \(Int(bounds.width))x\(Int(bounds.height)) fit \(text(fits)), sized \(text(sized)), reported \(text(reported)), owner \(text(owner))"
        if sized != fits { return detail }
        guard geometry.ownsGeometry else { return nil }
        if reported != fits { return detail }
        // The owner's side: only where it applies this view's grid and nothing of it is in flight (the caller's
        // fact, `ownerSettled`: no grid of this terminal waits to be sent or for its echo).
        guard ownerSettled, session?.io.appliesViewGrid(reporting: false) == true, let owner, owner != fits else { return nil }
        return detail
    }
}
