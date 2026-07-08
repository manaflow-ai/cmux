import Foundation

/// Serializes the phone→Mac natural-grid viewport reports and their
/// effective-grid echoes so they cannot race each other.
///
/// `GhosttySurfaceView` emits a natural-grid report whenever its viewport
/// changes (keyboard show/hide, rotation, zoom settle). Each report
/// round-trips to the Mac as an async RPC whose reply echoes the daemon's
/// effective grid. Firing one detached Task per report (the previous
/// coordinator shape) allowed two hazards:
///
/// 1. **Send scrambling** — Task scheduling order is unspecified, so the
///    keyboard-DOWN report could reach the daemon BEFORE the earlier
///    keyboard-UP report, leaving the shared PTY on the stale keyboard-up
///    grid.
/// 2. **Stale echo application** — replies resolve out of order, so the echo
///    of an old, smaller report could land last and re-pin the phone to a
///    grid it already outgrew. The natural grid is unchanged afterwards, so
///    nothing re-reports and the letterbox (empty space above the terminal)
///    is permanent.
///
/// The scheduler closes both: reports are sent strictly one at a time in
/// submission order, a newer submission supersedes an unsent older one (the
/// daemon only needs the newest), and an echo is applied only when its report
/// is still the newest one submitted.
@MainActor
public final class TerminalViewportReportScheduler {
    /// One natural-grid report, stamped with the surface's monotonically
    /// increasing report ID (see `GhosttySurfaceViewDelegate`'s `didResize`).
    public struct Report: Equatable, Sendable {
        /// The surface's monotonic stamp for this report; echoes hand it back
        /// so stale replies are recognized.
        public let id: UInt64
        /// Reported column count (at the rendered font).
        public let columns: Int
        /// Reported row count (base-font capacity; see `TerminalRowCapacityFit`).
        public let rows: Int

        /// Creates a report from the surface's stamp and grid counts.
        public init(id: UInt64, columns: Int, rows: Int) {
            self.id = id
            self.columns = columns
            self.rows = rows
        }
    }

    /// The daemon's effective grid for one report: the min-per-axis result of
    /// the viewport negotiation, as returned by the `send` RPC.
    public typealias EffectiveGrid = (columns: Int, rows: Int)

    private let send: @MainActor (Report) async -> EffectiveGrid?
    private let apply: @MainActor (Report, EffectiveGrid?) -> Void
    private let onReportSuperseded: @MainActor () -> Void
    private let onReportCancelled: @MainActor () -> Void
    private let onStaleEcho: @MainActor () -> Void
    private var pending: Report?
    private var draining = false
    /// The drain loop, stored so teardown can cancel it explicitly instead of
    /// relying on the weak-self exit at the next loop check.
    private var drainTask: Task<Void, Never>?
    /// The one in-flight RPC. Cancelled when a newer report supersedes it so a
    /// stalled send cannot delay the newest geometry for the transport's full
    /// deadline (cancellation is cooperative: a transport that ignores it just
    /// completes and its echo is discarded as stale).
    private var inFlightSend: Task<EffectiveGrid?, Never>?

    /// - Parameters:
    ///   - send: Performs the viewport RPC for one report and returns the
    ///     daemon's effective grid (nil when the RPC dropped or timed out).
    ///     Called serially: never more than one send in flight.
    ///   - apply: Delivers a settled echo. Called only when the sent report is
    ///     still the newest submitted one, so applying it cannot regress the
    ///     grid; `nil` effective grids are delivered too (the caller re-arms
    ///     the report retry).
    ///   - onReportSuperseded: Diagnostics hook fired synchronously inside
    ///     ``submit(_:)`` when a newer report replaces an UNSENT pending one.
    ///     Runs on the main actor before the superseding report is stored; do
    ///     only cheap observation work here, never re-entrant `submit` calls.
    ///   - onReportCancelled: Diagnostics hook fired synchronously inside
    ///     ``submit(_:)`` immediately before an in-flight send is cancelled
    ///     because a newer report superseded it. This is the single ownership
    ///     point for counting cancellations; the send's own
    ///     `CancellationError` unwind must not count the same event again.
    ///     Not fired by ``cancel()`` (owner teardown is not a supersession).
    ///   - onStaleEcho: Diagnostics hook fired synchronously inside the drain
    ///     loop when a completed send's echo is discarded because a newer
    ///     report was submitted while it was in flight.
    public init(
        send: @escaping @MainActor (Report) async -> EffectiveGrid?,
        apply: @escaping @MainActor (Report, EffectiveGrid?) -> Void,
        onReportSuperseded: @escaping @MainActor () -> Void = {},
        onReportCancelled: @escaping @MainActor () -> Void = {},
        onStaleEcho: @escaping @MainActor () -> Void = {}
    ) {
        self.send = send
        self.apply = apply
        self.onReportSuperseded = onReportSuperseded
        self.onReportCancelled = onReportCancelled
        self.onStaleEcho = onStaleEcho
    }

    /// Queue `report` as the newest report and start draining if idle. An
    /// unsent older report is superseded, an in-flight send is cancelled (its
    /// echo would be stale anyway), and a completed in-flight report's echo is
    /// discarded on return because this newer report exists.
    public func submit(_ report: Report) {
        if pending != nil {
            onReportSuperseded()
        }
        pending = report
        if inFlightSend != nil {
            onReportCancelled()
            inFlightSend?.cancel()
        }
        guard !draining else { return }
        draining = true
        drainTask = Task { @MainActor [weak self] in
            while let next = self?.takePending() {
                guard let self else { return }
                let sendTask = Task { @MainActor [send = self.send] in
                    await send(next)
                }
                self.inFlightSend = sendTask
                let effective = await sendTask.value
                // Teardown cancelled the drain while the send was in flight:
                // never apply into a dismantled surface, and leave
                // `inFlightSend` alone (a successor drain may own it by now).
                guard !Task.isCancelled else { return }
                self.inFlightSend = nil
                // A newer report landed while this one was in flight: its
                // echo is stale by construction. Skip it; the loop sends the
                // newer report next.
                if self.pending == nil {
                    self.apply(next, effective)
                } else {
                    self.onStaleEcho()
                }
            }
            self?.draining = false
            self?.drainTask = nil
        }
    }

    /// Stop the drain loop and the in-flight RPC. Called by the owner on
    /// detach so pending work cannot apply into a surface being torn down.
    public func cancel() {
        inFlightSend?.cancel()
        inFlightSend = nil
        drainTask?.cancel()
        drainTask = nil
        pending = nil
        draining = false
    }

    private func takePending() -> Report? {
        defer { pending = nil }
        return pending
    }
}
