import AppKit
import GhosttyNextKit

#if DEBUG
extension TerminalSurfaceView {
    /// DEBUG `debug.surfaces`: Ghostty's grid in this view's points (cell size and the padding
    /// before the first cell), so a script can post a real click at a cell through
    /// `debug.mouse` and Ghostty's own hit testing (an OSC 8 hyperlink's Cmd-click). Nil
    /// before the surface reports its grid.
    public func debugGridMetrics() -> (cellWidth: Double, cellHeight: Double, paddingLeft: Double, paddingTop: Double)? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cell_width > 0, metrics.cell_height > 0 else { return nil }
        return (Double(metrics.cell_width), Double(metrics.cell_height), Double(metrics.padding_left), Double(metrics.padding_top))
    }
}
#endif
