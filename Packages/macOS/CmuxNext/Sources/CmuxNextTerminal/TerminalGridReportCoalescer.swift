import CmuxNextTerminalGeometry
import CmuxNextWakeups

/// Coalesces the grid reports a terminal view sends to its PTY owner (the cmux-tui daemon), which resizes
/// the PTY and sends SIGWINCH for each one.
///
/// During a key resize or a divider drag the view's fit grid changes on almost every display frame. This
/// follows Ghostty.app's own rule (`src/termio/Thread.zig`, `min_ms = 25`): the shell sees at most one
/// resize per ``defaultInterval``, and always the newest grid.
///
/// - A new grid while nothing waits starts one ``interval`` timer; it is not sent at once.
/// - Each later grid inside that window replaces the waiting one (no timer work: a compare and a store).
/// - When the timer fires, the newest waiting grid is sent once and the window ends. The next change
///   starts a new window.
/// - A grid equal to the last sent grid sends nothing: one that arrives while nothing waits starts no
///   window, and a waiting grid that changed back to the last sent grid makes the fire send nothing.
///
/// ``flush()`` ends the window now. Call it when the gesture ends (the key resize or the drag lands, the
/// pane's layout spring settles) and for a report at rest, so the shell gets the final grid in the same
/// turn instead of up to 25 ms later. ``reportNow(_:)`` is the forced report (a new PTY owner, the
/// session's first report): it sends even a grid equal to the last sent one. ``cancel()`` drops the
/// waiting grid (the view is hidden, closed or detached from its session).
///
/// Main thread only. It never blocks or sleeps: the window is a ``DemandTimer`` on the injected clock, so
/// tests drive it with a manual clock. A grid inside a window allocates nothing; a new window costs the
/// timer's one task.
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
    /// Counts windows, so a fire that was already on its way when its window ended (``flush()``,
    /// ``cancel()``) sends nothing into the next window.
    private var window: UInt64 = 0

    /// - Parameters:
    ///   - interval: The coalescing window; Ghostty's 25 ms by default.
    ///   - clock: The window timer's clock; the terminal session passes its clock, tests a manual one.
    ///   - send: Reports one grid to the PTY owner. Called on the main thread, at most once per window.
    init(interval: Duration = TerminalGridReportCoalescer.defaultInterval,
         clock: any Clock<Duration> = ContinuousClock(),
         send: @escaping @MainActor (TerminalGridSize) -> Void) {
        self.interval = interval
        self.send = send
        timer = DemandTimer(owner: "TerminalGridReportCoalescer.window", clock: clock)
    }

    /// The view's fit grid is now `grid`: it waits for the open window, or opens one.
    /// DIAG: (event, grid, time).
    var diagTrace: [(String, TerminalGridSize?, ContinuousClock.Instant)] = []

    func viewSized(_ grid: TerminalGridSize) {
        diagTrace.append(("viewSized pending=\(pending.map { "\($0.columns)x\($0.rows)" } ?? "-")", grid, .now))
        if pending != nil {
            pending = grid
            return
        }
        guard grid != lastSent else { return }
        pending = grid
        window &+= 1
        let window = window
        timer.schedule(after: interval) { @MainActor [weak self] in
            self?.windowEnded(window)
        }
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

    private func windowEnded(_ ended: UInt64) {
        diagTrace.append(("fire window=\(ended) current=\(window)", pending, .now))
        guard ended == window, let grid = pending else { return }
        pending = nil
        deliver(grid)
    }

    private func deliver(_ grid: TerminalGridSize) {
        diagTrace.append(("deliver lastSent=\(lastSent.map { "\($0.columns)x\($0.rows)" } ?? "-")", grid, .now))
        guard grid != lastSent else { return }
        lastSent = grid
        send(grid)
    }
}
