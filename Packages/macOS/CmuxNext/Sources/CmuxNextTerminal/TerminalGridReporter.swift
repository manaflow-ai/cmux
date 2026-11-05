import CmuxNextTerminalGeometry
import GhosttyNextKit

/// A terminal view's grid reports to its PTY owner (the cmux-tui daemon resizes the PTY and sends SIGWINCH for each).
/// Every report goes through one ``TerminalGridReportCoalescer``, so its last sent grid is the PTY's: a person's divider
/// drag sends its grids while it moves, coalesced as Ghostty.app does (cmux-ad m29: the newest grid at most once per
/// 25 ms, so a full-screen program, which the reflow preview does not re-wrap, follows its pane); every other report
/// (at rest, forced, a spring's final grid) goes now.
@MainActor
final class TerminalGridReporter {
    private weak var view: TerminalSurfaceView?
    /// The report going out now is a layout spring's final grid (the PTY owner sends it in the caller's turn).
    private var sendingFinal = false
    private(set) lazy var coalescer = TerminalGridReportCoalescer { [weak self] in self?.deliver($0) }

    init(view: TerminalSurfaceView) {
        self.view = view
    }

    /// Whether a drag's grid waits in the coalescer's window.
    var isWaiting: Bool { coalescer.isWaiting }

    /// A drag's grid: it waits for the window, or opens one.
    func coalesced(_ grid: TerminalGridSize) {
        coalescer.viewSized(grid)
    }

    /// `grid` goes now; a grid that waits is older and is dropped. `final`: a layout spring's final grid.
    func now(_ grid: TerminalGridSize, final: Bool = false) {
        sendingFinal = final
        defer { sendingFinal = false }
        coalescer.reportNow(grid)
    }

    /// The drag ended (or will not end for this view): the grid that waits goes now.
    func flush() {
        coalescer.flush()
    }

    private func deliver(_ grid: TerminalGridSize) {
        guard let view, let surface = view.surface else { return }
        TerminalSurfaceView.gridReports &+= 1
        let size = ghostty_surface_size(surface)
        let metrics = TerminalGridMetrics(cellWidth: Int(size.cell_width_px), cellHeight: Int(size.cell_height_px),
                                          paddingWidth: 0, paddingHeight: 0)
        let cells = metrics.cellPixels(of: grid)
        view.session?.surfaceDidReport(grid: grid, pixelWidth: cells.width, pixelHeight: cells.height, final: sendingFinal)
    }
}
