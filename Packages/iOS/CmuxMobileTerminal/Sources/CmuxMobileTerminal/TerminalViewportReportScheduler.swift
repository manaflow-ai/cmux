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
        public let id: UInt64
        public let columns: Int
        public let rows: Int

        public init(id: UInt64, columns: Int, rows: Int) {
            self.id = id
            self.columns = columns
            self.rows = rows
        }
    }

    public typealias EffectiveGrid = (columns: Int, rows: Int)

    private let send: @MainActor (Report) async -> EffectiveGrid?
    private let apply: @MainActor (Report, EffectiveGrid?) -> Void
    private var pending: Report?
    private var draining = false

    /// - Parameters:
    ///   - send: Performs the viewport RPC for one report and returns the
    ///     daemon's effective grid (nil when the RPC dropped or timed out).
    ///     Called serially: never more than one send in flight.
    ///   - apply: Delivers a settled echo. Called only when the sent report is
    ///     still the newest submitted one, so applying it cannot regress the
    ///     grid; `nil` effective grids are delivered too (the caller re-arms
    ///     the report retry).
    public init(
        send: @escaping @MainActor (Report) async -> EffectiveGrid?,
        apply: @escaping @MainActor (Report, EffectiveGrid?) -> Void
    ) {
        self.send = send
        self.apply = apply
    }

    /// Queue `report` as the newest report and start draining if idle. An
    /// unsent older report is superseded, and an in-flight report's echo is
    /// discarded on return because this newer report exists.
    public func submit(_ report: Report) {
        pending = report
        guard !draining else { return }
        draining = true
        Task { @MainActor [weak self] in
            while let next = self?.takePending() {
                guard let self else { return }
                let effective = await self.send(next)
                // A newer report landed while this one was in flight: its
                // echo is stale by construction. Skip it; the loop sends the
                // newer report next.
                if self.pending == nil {
                    self.apply(next, effective)
                }
            }
            self?.draining = false
        }
    }

    private func takePending() -> Report? {
        defer { pending = nil }
        return pending
    }
}
