import CmuxNextTerminalGeometry
import GhosttyNextKit

/// A terminal view's grid reports to its PTY owner (the cmux-tui daemon resizes the PTY and sends SIGWINCH for each).
/// Every report goes through one ``TerminalGridReportCoalescer``, so its last sent grid is the PTY's: a person's divider
/// drag sends its grids while it moves, coalesced to the display refresh (cmux-ad m29, RESIZE P0 6: the newest grid at
/// most once per refresh, so a full-screen program, which the reflow preview does not re-wrap, follows its pane); every other report
/// (at rest, forced, a spring's final grid) goes now. A drag's grid, like a key resize's, is the grid of the size asked of
/// Ghostty, and the presenter holds that size's frame for the program's redraw (RESIZE P0 12, m55 "terminals: zero lag";
/// it replaced cmux-ad m29's rule that a drag's grid waits until its size shows, which made the program redraw a refresh
/// after the divider).
@MainActor
final class TerminalGridReporter {
    private weak var view: TerminalSurfaceView?
    /// Its window ends at the next refresh of the view's window (T-KEYS B3: that window's presenter ticks it; RESIZE P0 6:
    /// not at 25 ms); its timer stays the backstop.
    private(set) lazy var coalescer = TerminalGridReportCoalescer(clock: clock, ticks: { [weak self] in
        guard let self else { return nil }
        if let ticks { return ticks() }
        return view?.window.map(TerminalFramePresenter.forWindow)
    }) { [weak self] in self?.deliver($0) }
    private let clock: any Clock<Duration>
    private let ticks: (@MainActor () -> (any TerminalGridReportTicks)?)?

    /// - Parameters:
    ///   - clock: The coalescing window's backstop clock; tests pass a manual one, so a drag needs no real sleep.
    ///   - ticks: The refreshes that end a window; nil: the view's window presenter. Tests pass refreshes stepped by
    ///     hand, so no real frame tick ends a window during the test.
    init(view: TerminalSurfaceView, clock: any Clock<Duration> = ContinuousClock(),
         ticks: (@MainActor () -> (any TerminalGridReportTicks)?)? = nil) {
        self.view = view
        self.clock = clock
        self.ticks = ticks
    }

    /// Whether a drag's grid waits in the coalescer's window.
    var isWaiting: Bool { coalescer.isWaiting }
    /// The pointer let go (a drag's mouse-up, in its turn): the newest grid goes to the program now, not when the
    /// window or the release's landing ends (the RESIZE OWNER's film of px-col-drag-2, STATUS 15707: the program was
    /// whole only 4 refreshes after its pane rested). Sizes a release spring moves through after this coalesce again.
    func release() {
        coalescer.flush()
    }

    /// A drag's or a key spring's grid: it waits for the window, or opens one. `waitsForRefresh`: never at once;
    /// `replacesUnshown`: at once, in place of a grid whose frame never shows
    /// (``TerminalGridReportCoalescer/viewSized(_:waitsForRefresh:replacesUnshown:)``).
    func coalesced(_ grid: TerminalGridSize, waitsForRefresh: Bool = false, replacesUnshown: Bool = false) {
        coalescer.viewSized(grid, waitsForRefresh: waitsForRefresh, replacesUnshown: replacesUnshown)
    }

    /// `grid` goes now; a grid that waits is older and is dropped.
    func now(_ grid: TerminalGridSize) {
        coalescer.reportNow(grid)
    }

    /// The drag ended (or will not end for this view): the grid that waits goes now.
    func flush() {
        coalescer.flush()
    }

    private func deliver(_ grid: TerminalGridSize) {
        guard let view, let surface = view.surface else { return }
        TerminalSurfaceView.gridReports &+= 1
        // The refresh the program gets this grid in: a hold for its redraw at it counts its bound from here (RESIZE P0 23).
        if view.session != nil { view.frameOwnership.gridSentEpoch = view.window.map(TerminalFramePresenter.forWindow)?.currentEpoch }
        let size = ghostty_surface_size(surface)
        let metrics = TerminalGridMetrics(cellWidth: Int(size.cell_width_px), cellHeight: Int(size.cell_height_px),
                                          paddingWidth: 0, paddingHeight: 0)
        let cells = metrics.cellPixels(of: grid)
        view.session?.surfaceDidReport(grid: grid, pixelWidth: cells.width, pixelHeight: cells.height)
    }
}
