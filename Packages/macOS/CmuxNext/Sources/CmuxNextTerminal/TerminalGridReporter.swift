import CmuxNextTerminalGeometry
import GhosttyNextKit

/// A terminal view's grid reports to its PTY owner (the cmux-tui daemon resizes the PTY and sends SIGWINCH for each).
/// Every report goes through one ``TerminalGridReportCoalescer``, so its last sent grid is the PTY's: a person's divider
/// drag sends its grids while it moves, coalesced as Ghostty.app does (cmux-ad m29: the newest grid at most once per
/// 25 ms, so a full-screen program, which the reflow preview does not re-wrap, follows its pane); every other report
/// (at rest, forced, a spring's final grid) goes now. A drag's grid is the grid of a size shown on screen: a size asked of
/// Ghostty and not shown yet waits for the commit that shows it with its frame (``shown(_:live:)``), so the program never
/// redraws at a size the person does not see (the RESIZE OWNER's rule, cmux-ad m29).
@MainActor
final class TerminalGridReporter {
    private weak var view: TerminalSurfaceView?
    /// The report going out now is a layout spring's final grid (the PTY owner sends it in the caller's turn).
    private var sendingFinal = false
    private(set) lazy var coalescer = TerminalGridReportCoalescer(clock: clock) { [weak self] in self?.deliver($0) }
    private let clock: any Clock<Duration>

    /// - Parameter clock: The coalescing window's clock; tests pass a manual one, so a drag needs no real sleep.
    init(view: TerminalSurfaceView, clock: any Clock<Duration> = ContinuousClock()) {
        self.view = view
        self.clock = clock
    }

    /// Whether a drag's grid waits in the coalescer's window.
    var isWaiting: Bool { coalescer.isWaiting }
    /// A drag's grid that waits for its size to show (asked of Ghostty, not shown yet); nil when none waits.
    private(set) var awaitingShown: TerminalGridSize?

    /// A drag's grid: coalesced when its size shows now (the bounds took it), else when the presenter shows it.
    func drag(_ grid: TerminalGridSize, shownNow: Bool) {
        if shownNow { coalesced(grid) } else { awaitingShown = grid }
    }

    /// The presenter's commit showed a size with its frame (``TerminalSurfaceView/frameDidLand()``): the grid that size
    /// fits goes, coalesced while the drag `live`s, else now (a size that landed after the drag ended).
    func shown(_ grid: TerminalGridSize?, live: Bool) {
        guard awaitingShown != nil, let grid else { return }
        awaitingShown = nil
        if live { coalesced(grid) } else { now(grid) }
    }

    /// The presenter cancelled the size a drag's grid waited for (the view was hidden, or left its window, before its
    /// frame landed): the view took that size's bounds without it, and its geometry counts that grid as reported, so the
    /// grid goes now (coalesced while the drag `live`s). Without this the program kept an older grid until the next
    /// resize (review of #36631). Nothing shows the size either way: the view is hidden or gone.
    func shownCancelled(live: Bool) {
        guard let grid = awaitingShown else { return }
        awaitingShown = nil
        if live { coalesced(grid) } else { now(grid) }
    }

    /// A drag's grid: it waits for the window, or opens one.
    func coalesced(_ grid: TerminalGridSize) {
        coalescer.viewSized(grid)
    }

    /// `grid` goes now; a grid that waits is older and is dropped. `final`: a layout spring's final grid.
    func now(_ grid: TerminalGridSize, final: Bool = false) {
        awaitingShown = nil // a size that waits to show is older than this grid; its landing sends nothing after it
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
