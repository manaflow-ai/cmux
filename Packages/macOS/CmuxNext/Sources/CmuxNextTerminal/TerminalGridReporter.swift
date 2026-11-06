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
    /// Its window also ends at the first refresh of the view's window at or after 25 ms (T-KEYS B3: that window's presenter
    /// ticks it); its timer stays the backstop.
    private(set) lazy var coalescer = TerminalGridReportCoalescer(clock: clock, ticks: { [weak self] in
        self?.view?.window.map(TerminalFramePresenter.forWindow)
    }) { [weak self] in self?.deliver($0) }
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
        print("TKTRACE t=\(Self.traceMs()) DRAG view=\(view.map { ObjectIdentifier($0).hashValue % 100000 } ?? 0) shownNow=\(shownNow) grid=\(String(describing: grid))")
        if shownNow { coalesced(grid) } else { awaitingShown = grid }
    }

    /// The presenter's commit showed a size with its frame (``TerminalSurfaceView/frameDidLand()``): the grid that size
    /// fits goes, coalesced while the drag `live`s, else now (a size that landed after the drag ended).
    func shown(_ grid: TerminalGridSize?, live: Bool) {
        print("TKTRACE t=\(Self.traceMs()) SHOWN view=\(view.map { ObjectIdentifier($0).hashValue % 100000 } ?? 0) live=\(live) awaiting=\(String(describing: awaitingShown)) grid=\(String(describing: grid))")
        guard awaitingShown != nil, let grid else { return }
        awaitingShown = nil
        if live { coalesced(grid) } else { now(grid) }
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

    /// A drag's grid: it waits for the window, or opens one.
    func coalesced(_ grid: TerminalGridSize) {
        print("TKTRACE t=\(Self.traceMs()) COALESCED view=\(view.map { ObjectIdentifier($0).hashValue % 100000 } ?? 0)  grid=\(String(describing: grid))")
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
        print("TKTRACE t=\(Self.traceMs()) FLUSH view=\(view.map { ObjectIdentifier($0).hashValue % 100000 } ?? 0) pending=\(String(describing: coalescer.pending))")
        coalescer.flush()
    }

    /// DIAG (never merge): one clock for the drag shown-grid trace.
    nonisolated static let traceEpoch = ContinuousClock.now
    nonisolated static func traceMs() -> String {
        let d = traceEpoch.duration(to: .now)
        return String(format: "%.2f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    private func deliver(_ grid: TerminalGridSize) {
        guard let view, let surface = view.surface else { return }
        print("TKTRACE t=\(Self.traceMs()) SEND view=\(ObjectIdentifier(view).hashValue % 100000) grid=\(grid.columns)x\(grid.rows) final=\(sendingFinal) inFlight=\(String(describing: view.frameOwnership.inFlight)) bounds=\(view.bounds.size) drag=\(view.isFollowingResizeGesture) stack=\(Thread.callStackSymbols.dropFirst(1).prefix(7).map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? "?" })")
        TerminalSurfaceView.gridReports &+= 1
        let size = ghostty_surface_size(surface)
        let metrics = TerminalGridMetrics(cellWidth: Int(size.cell_width_px), cellHeight: Int(size.cell_height_px),
                                          paddingWidth: 0, paddingHeight: 0)
        let cells = metrics.cellPixels(of: grid)
        view.session?.surfaceDidReport(grid: grid, pixelWidth: cells.width, pixelHeight: cells.height, final: sendingFinal)
    }
}
