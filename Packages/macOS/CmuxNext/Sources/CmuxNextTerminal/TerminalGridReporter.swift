import CmuxNextTerminalGeometry
import GhosttyNextKit

/// A terminal view's grid reports to its PTY owner (the cmux-tui daemon resizes the PTY and sends SIGWINCH for each).
/// Every report goes through one ``TerminalGridReportCoalescer``, so its last sent grid is the PTY's: a person's divider
/// drag sends its grids while it moves, coalesced to the display refresh (cmux-ad m29, RESIZE P0 6: the newest grid at
/// most once per refresh, so a full-screen program, which the reflow preview does not re-wrap, follows its pane); every other report
/// (at rest, forced, a spring's final grid) goes now. A drag's grid is the grid of a size shown on screen: a size asked of
/// Ghostty and not shown yet waits for the commit that shows it with its frame (``shown(_:live:)``), so the program never
/// redraws at a size the person does not see (the RESIZE OWNER's rule, cmux-ad m29).
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
    /// A drag's grid that waits for its size to show (asked of Ghostty, not shown yet); nil when none waits.
    private(set) var awaitingShown: TerminalGridSize?
    /// The pointer let go while a size was in flight: that size's grid goes the moment it shows, not coalesced.
    private var sendsAwaitedNow = false

    /// A drag's grid: coalesced when its size shows now (the bounds took it), else when the presenter shows it.
    func drag(_ grid: TerminalGridSize, shownNow: Bool) {
        if shownNow { coalesced(grid) } else { awaitingShown = grid }
    }

    /// The presenter's commit showed a size with its frame (``TerminalSurfaceView/frameDidLand()``): the grid that size
    /// fits goes, coalesced while the drag `live`s, else now (a size that landed after the drag ended).
    func shown(_ grid: TerminalGridSize?, live: Bool) {
        guard awaitingShown != nil, let grid else { return }
        awaitingShown = nil
        if live, !sendsAwaitedNow { coalesced(grid) } else { now(grid) }
        sendsAwaitedNow = false
    }

    /// The pointer let go (a drag's mouse-up, in its turn): the newest grid goes to the program now, not when the
    /// window or the release's landing ends (the RESIZE OWNER's film of px-col-drag-2, STATUS 15707: the program was
    /// whole only 4 refreshes after its pane rested). The newest shown grid is the one that waits in the window; if a newer
    /// size is in flight, the waiting grid is older and is dropped, and that size's grid goes when its frame shows.
    /// Sizes a release spring moves through after this coalesce again.
    func release() {
        guard awaitingShown == nil else {
            coalescer.cancel()
            sendsAwaitedNow = true
            return
        }
        coalescer.flush()
    }

    /// The presenter cancelled the size a drag's grid waited for (the view was hidden, or left its window, before its
    /// frame landed). Without a report the program kept an older grid until the next resize (review of #36631). The grid
    /// that goes is `taken`, the grid of the bounds the view took at the cancel, never the stored one: the stored grid is
    /// the committed bounds' grid when the size was asked (T-KEYS: the PTY gets only shown grids), older than the bounds
    /// the view takes now (frame-owner-s2's rule for #36478). It goes coalesced while the drag `live`s, else as a grid at
    /// rest (nothing when the PTY has it). `taken` nil (the view is not shown, so its grid is not measured): the caller
    /// sends the view's grid when it shows. Returns whether a drag grid waited.
    @discardableResult
    func shownCancelled(_ taken: TerminalGridSize?, live: Bool) -> Bool {
        guard awaitingShown != nil else { return false }
        awaitingShown = nil
        guard let taken else { return true }
        coalescer.viewSized(taken)
        if !live { coalescer.flush() }
        return true
    }

    /// A drag's or a key spring's grid: it waits for the window, or opens one. `waitsForRefresh`: never at once;
    /// `replacesUnshown`: at once, in place of a grid whose frame never shows
    /// (``TerminalGridReportCoalescer/viewSized(_:waitsForRefresh:replacesUnshown:)``).
    func coalesced(_ grid: TerminalGridSize, waitsForRefresh: Bool = false, replacesUnshown: Bool = false) {
        coalescer.viewSized(grid, waitsForRefresh: waitsForRefresh, replacesUnshown: replacesUnshown)
    }

    /// `grid` goes now; a grid that waits is older and is dropped.
    func now(_ grid: TerminalGridSize) {
        awaitingShown = nil // a size that waits to show is older than this grid; its landing sends nothing after it
        sendsAwaitedNow = false
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
        view.session?.surfaceDidReport(grid: grid, pixelWidth: cells.width, pixelHeight: cells.height)
    }
}
