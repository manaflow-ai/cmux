import CmuxNextTerminalGeometry
import CmuxNextWakeups

/// Coalesces the grid reports a terminal view sends to its PTY owner (the cmux-tui daemon), which resizes
/// the PTY and sends SIGWINCH for each one.
///
/// During a key resize or a divider drag the view's fit grid changes on almost every display frame. The shell sees
/// at most one resize per display refresh, and always the newest grid: Chromium's rule for a renderer's size (the
/// new size goes with the next frame, its visual properties at the begin-frame), not Ghostty.app's 25 ms timer
/// (`src/termio/Thread.zig`, `min_ms`). RESIZE P0 6 (cause T): a held key moves a pane 10-20 pt per 120 Hz refresh,
/// and one grid per 25 ms window (4 refreshes) left the program's own drawing 40-80 pt off its pane edge (the m20
/// judge allows 2 refreshes and one cell; px-keys-held-2-s1r x1, P0 runner 2b757265: 63 frames).
///
/// - While frames run (the view's window has a presenter, ``TerminalGridReportTicks``), the first new grid after a
///   refresh goes at once, in the turn that showed its size (RESIZE P0 7, cause T): a key spring lands one size per
///   refresh at the end of its turn, and a grid that waited for the next refresh made the program's redraw race the next
///   draw-ahead render, so it showed 3 refreshes after its pane (m20 allows 2; px-keys-held-2-s1r x1, fd7a1664 on cmux21
///   1x: 46 terminal frames, every PTY grid 3-6 ms after the trace sample that showed its width). Chromium's
///   `RenderWidgetHostImpl::SynchronizeVisualProperties` sends a new size at once and keeps one in flight. A send spends
///   the refresh (``spent``) until the next one.
/// - A new grid in a refresh that already sent one, or with no frames running, opens a window; it is not sent at once.
/// - Each later grid inside that window replaces the waiting one (no timer work: a compare and a store).
/// - The window ends at the next display refresh of the view's window (its frame ticks), or when its ``DemandTimer``
///   fires after ``interval``, whichever comes first: the newest waiting grid is sent once, and spends that refresh.
///   The next change opens a new window. The refresh is the clock that runs while frames run (a timer task can come
///   late on a loaded main thread: 124 ms for a 25 ms window, diag bf2b674a); the timer ends a window no refresh
///   reaches (no frames run, a test that steps frames by hand).
/// - A grid equal to the last sent grid sends nothing: one that arrives while nothing waits starts no
///   window, and a waiting grid that changed back to the last sent grid makes the fire send nothing.
///
/// ``flush()`` ends the window now. Call it when the gesture ends (the key resize or the drag lands, the
/// pane's layout spring settles) and for a report at rest, so the shell gets the final grid in the same
/// turn instead of at the next refresh. ``reportNow(_:)`` is the forced report (a new PTY owner, the
/// session's first report): it sends even a grid equal to the last sent one. ``cancel()`` drops the
/// waiting grid (the view is hidden, closed or detached from its session).
///
/// Main thread only. It never blocks or sleeps: the window's backstop is the injected clock and its ticks the
/// injected tick source, so tests drive both by hand. A grid inside a window allocates nothing. The backstop is armed
/// only when none is pending and a refresh does not cancel it, so windows that refreshes end (one per frame while a
/// pane moves) cost one timer task per ``interval``, not one per frame; a window no refresh reaches waits at most two
/// intervals.
@MainActor
final class TerminalGridReportCoalescer {
    /// The backstop of a window no refresh reaches: Ghostty.app's resize coalescing window (`Thread.zig`, `min_ms`).
    nonisolated static let defaultInterval: Duration = .milliseconds(25)

    /// How long a window that no refresh reaches waits before it sends its newest grid.
    let interval: Duration

    /// The grid the open window will send when it fires; nil while no window is open.
    private(set) var pending: TerminalGridSize?

    /// The last grid handed to `send`; nil before the first send.
    private(set) var lastSent: TerminalGridSize?

    /// Whether a window's timer is open (a grid waits).
    var isWaiting: Bool { pending != nil }

    /// A grid went since the last refresh of the view's window (at once, or at that refresh): the next new grid waits for
    /// the next refresh. Cleared by a refresh that sends nothing.
    private(set) var spent = false

    private let send: @MainActor (TerminalGridSize) -> Void
    private let timer: DemandTimer
    /// The refreshes of the view's window, nil out of a window: an open window ends at the next one.
    private let ticks: @MainActor () -> (any TerminalGridReportTicks)?
    /// Counts windows, so a fire that was already on its way when its window ended (``flush()``,
    /// ``cancel()``) sends nothing into the next window.
    private var window: UInt64 = 0

    /// - Parameters:
    ///   - interval: The backstop of a window no refresh reaches; Ghostty's 25 ms by default.
    ///   - clock: The backstop timer's clock; tests pass a manual one.
    ///   - ticks: The display refreshes that end a window (the view's window presenter); nil: the timer only.
    ///   - send: Reports one grid to the PTY owner. Called on the main thread, at most once per window.
    init(interval: Duration = TerminalGridReportCoalescer.defaultInterval,
         clock: any Clock<Duration> = ContinuousClock(),
         ticks: @escaping @MainActor () -> (any TerminalGridReportTicks)? = { nil },
         send: @escaping @MainActor (TerminalGridSize) -> Void) {
        self.interval = interval
        self.send = send
        self.ticks = ticks
        timer = DemandTimer(owner: "TerminalGridReportCoalescer.window", clock: clock)
    }

    /// The view's fit grid is now `grid`: it waits for the open window, or opens one.
    func viewSized(_ grid: TerminalGridSize) {
        if pending != nil {
            pending = grid
            return
        }
        guard grid != lastSent else { return }
        let source = ticks()
        if let source, !spent {
            // Frames run and this refresh sent nothing: the grid goes in the turn that showed its size.
            spent = true
            deliver(grid)
            source.tickGridReports(self)
            return
        }
        pending = grid
        window &+= 1
        armBackstop()
        source?.tickGridReports(self)
    }

    /// A display refresh of the view's window (``TerminalGridReportTicks``): the open window ends now and its newest grid
    /// goes, which spends this refresh; with nothing waiting, the refresh is unspent. Returns whether to tick it at the next
    /// refresh (while a grid went in this one).
    func frameTicked() -> Bool { // perf-hot: 1ms motion-frame
        guard pending != nil else {
            spent = false
            return false
        }
        windowEnded(window)
        spent = true
        return true
    }

    /// Sends the waiting grid now (unless it is the last sent grid) and closes the window. Nothing waits:
    /// nothing is sent.
    func flush() {
        guard let grid = pending else { return }
        close()
        deliver(grid)
    }

    /// The forced report: sends `grid` now even when it equals the last sent grid, and drops the open
    /// window (its grid is older than this one).
    func reportNow(_ grid: TerminalGridSize) {
        close()
        lastSent = grid
        send(grid)
    }

    /// Drops the waiting grid and closes the window: nothing is sent.
    func cancel() {
        close()
    }

    private func close() {
        pending = nil
        window &+= 1
        timer.cancel()
    }

    /// The backstop of the open window: a window no refresh reaches (no frames run, frames stepped by hand) ends when
    /// it fires. A pending backstop (armed by an earlier window that a refresh ended) is kept, not reset: it fires for
    /// its own window only and then arms again for the window open at that time.
    private func armBackstop() {
        let armed = window
        timer.scheduleIfIdle(after: interval) { @MainActor [weak self] in
            self?.backstopFired(armed)
        }
    }

    private func backstopFired(_ armed: UInt64) {
        if armed == window {
            windowEnded(armed)
        } else if pending != nil {
            armBackstop()
        }
    }

    /// The window `ended` is over (its refresh, its backstop or a flush): its grid goes once; a later end of the same
    /// window finds it closed and sends nothing.
    private func windowEnded(_ ended: UInt64) {
        guard ended == window, let grid = pending else { return }
        pending = nil
        window &+= 1
        deliver(grid)
    }

    private func deliver(_ grid: TerminalGridSize) {
        guard grid != lastSent else { return }
        lastSent = grid
        send(grid)
    }
}

/// The display refreshes that end a coalescer's window (``TerminalGridReportCoalescer/frameTicked()``): the
/// view's window presenter (``TerminalFramePresenter``), whose frame client ticks while frames run.
protocol TerminalGridReportTicks: AnyObject {
    /// Ticks `coalescer` each refresh until it reports no window open.
    func tickGridReports(_ coalescer: TerminalGridReportCoalescer)
}
