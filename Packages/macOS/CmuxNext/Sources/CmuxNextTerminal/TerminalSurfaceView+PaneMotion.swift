import AppKit
public import CmuxNextDesign
import CmuxNextTerminalGeometry
import GhosttyNextKit

/// The pane's layout spring landed: the grid held while it moved goes to the owner now, once,
/// unless it is the final grid the spring's start already sent.
extension TerminalSurfaceView: PaneMotionSettling {
    public func paneMotionDidSettle() {
        endPaneMotion()
    }
}

/// A split or a close resizes the program in the terminal at the start of the pane's spring
/// (Lawrence 2026-10-23): the final grid goes to the PTY owner in the key's turn, and the surface
/// draws the owner's grid in the moving pane, cropped while the pane is smaller and padded with the
/// background while it is larger.
extension TerminalSurfaceView: PaneMotionTargeting {
    public func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        guard let surface else { return .top }
        let size = NSSize(width: max(0, bounds.width + sizeChange.width), height: max(0, bounds.height + sizeChange.height))
        let pixels = convertToBacking(size)
        var columns: UInt16 = 0
        var rows: UInt16 = 0
        guard pixels.width >= 1, pixels.height >= 1,
              ghostty_surface_fit_grid(surface, UInt32(pixels.width), UInt32(pixels.height), &columns, &rows)
        else { return .top }
        reportFinalGrid(TerminalGridSize(columns: Int(columns), rows: Int(rows)))
        return motionAnchor(growing: sizeChange.height > 0.5)
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
