import CmuxNextTerminalGeometry
import CmuxNextWakeups

/// Coalesces the grid reports a terminal view sends to its PTY owner (the cmux-tui daemon), which resizes
/// the PTY and sends SIGWINCH for each one.
///
/// During a key resize or a divider drag the view's fit grid changes on almost every display frame. This
/// follows Ghostty.app's own rule (`src/termio/Thread.zig`, `min_ms = 25`): the shell sees at most one
/// resize per ``defaultInterval``, and always the newest grid.
///
/// - A new grid while nothing waits opens one ``interval`` window; it is not sent at once.
/// - Each later grid inside that window replaces the waiting one (no timer work: a compare and a store).
/// - The window ends at the first display refresh at or after ``interval`` (its window's frame ticks,
///   ``TerminalGridReportTicks``), or when its ``DemandTimer`` fires, whichever comes first: the newest waiting
///   grid is sent once. The next change opens a new window. The refresh is the clock that runs while frames
///   run (a timer task can come late on a loaded main thread: 124 ms for a 25 ms window, diag bf2b674a); the
///   timer ends a window no refresh reaches (no frames run, a test that steps frames by hand).
/// - A grid equal to the last sent grid sends nothing: one that arrives while nothing waits starts no
///   window, and a waiting grid that changed back to the last sent grid makes the fire send nothing.
///
/// ``flush()`` ends the window now. Call it when the gesture ends (the key resize or the drag lands, the
/// pane's layout spring settles) and for a report at rest, so the shell gets the final grid in the same
/// turn instead of up to 25 ms later. ``reportNow(_:)`` is the forced report (a new PTY owner, the
/// session's first report): it sends even a grid equal to the last sent one. ``cancel()`` drops the
/// waiting grid (the view is hidden, closed or detached from its session).
///
/// Main thread only. It never blocks or sleeps: the window's time is the injected clock and its ticks the
/// injected tick source, so tests drive both by hand. A grid inside a window allocates nothing; a new window
/// costs the timer's one task.
@MainActor
final class TerminalGridReportCoalescer {
    /// Ghostty.app's resize coalescing window (`Thread.zig`, `min_ms`).
    nonisolated static let defaultInterval: Duration = .milliseconds(25)

    /// How long a window waits before it sends its newest grid.
    let interval: Duration

    /// The grid the open window will send when it fires; nil while no window is open.
    private(set) var pending: TerminalGridSize?

    /// The last grid handed to `send`; nil before the first send.
    private(set) var lastSent: TerminalGridSize?

    /// Whether a window's timer is open (a grid waits).
    var isWaiting: Bool { pending != nil }

    private let send: @MainActor (TerminalGridSize) -> Void
    private let timer: DemandTimer
    /// The refreshes of the view's window, nil out of a window: an open window is ticked each refresh.
    private let ticks: @MainActor () -> (any TerminalGridReportTicks)?
    /// Time since the coalescer was made, on its clock.
    private let elapsed: @Sendable () -> Duration
    /// When the open window opened (``elapsed``).
    private var opened: Duration = .zero
    /// Counts windows, so a fire that was already on its way when its window ended (``flush()``,
    /// ``cancel()``) sends nothing into the next window.
    private var window: UInt64 = 0

    /// - Parameters:
    ///   - interval: The coalescing window; Ghostty's 25 ms by default.
    ///   - clock: The window's clock (its timer and its refresh check); tests pass a manual one.
    ///   - ticks: The display refreshes that end a window early (the view's window presenter); nil: the timer only.
    ///   - send: Reports one grid to the PTY owner. Called on the main thread, at most once per window.
    init(interval: Duration = TerminalGridReportCoalescer.defaultInterval,
         clock: any Clock<Duration> = ContinuousClock(),
         ticks: @escaping @MainActor () -> (any TerminalGridReportTicks)? = { nil },
         send: @escaping @MainActor (TerminalGridSize) -> Void) {
        self.interval = interval
        self.send = send
        self.ticks = ticks
        elapsed = Self.stopwatch(clock)
        timer = DemandTimer(owner: "TerminalGridReportCoalescer.window", clock: clock)
    }

    private nonisolated static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }

    /// The view's fit grid is now `grid`: it waits for the open window, or opens one.
    func viewSized(_ grid: TerminalGridSize) {
        if pending != nil {
            pending = grid
            return
        }
        guard grid != lastSent else { return }
        pending = grid
        window &+= 1
        opened = elapsed()
        let window = window
        // The backstop: a window no refresh reaches (no frames run, frames stepped by hand) ends here.
        timer.schedule(after: interval) { @MainActor [weak self] in
            self?.windowEnded(window)
        }
        ticks()?.tickGridReports(self)
    }

    /// A display refresh of the view's window (``TerminalGridReportTicks``): the open window ends at the first one at or
    /// after ``interval``. Returns whether a window is still open (the source ticks it again).
    func frameTicked() -> Bool { // perf-hot: 1ms motion-frame
        guard pending != nil else { return false }
        guard elapsed() - opened >= interval else { return true }
        windowEnded(window)
        return false
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

    /// The window `ended` is over (its refresh or its timer, whichever came first): its grid goes once; the other
    /// finds the window closed and sends nothing.
    private func windowEnded(_ ended: UInt64) {
        guard ended == window, let grid = pending else { return }
        pending = nil
        window &+= 1
        timer.cancel()
        deliver(grid)
    }

    private func deliver(_ grid: TerminalGridSize) {
        guard grid != lastSent else { return }
        lastSent = grid
        send(grid)
    }
}

/// The display refreshes that end a coalescer's window early (``TerminalGridReportCoalescer/frameTicked()``): the
/// view's window presenter (``TerminalFramePresenter``), whose frame client ticks while frames run.
protocol TerminalGridReportTicks: AnyObject {
    /// Ticks `coalescer` each refresh until it reports no window open.
    func tickGridReports(_ coalescer: TerminalGridReportCoalescer)
}
