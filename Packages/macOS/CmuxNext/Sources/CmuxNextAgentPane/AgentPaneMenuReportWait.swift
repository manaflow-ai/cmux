import Foundation
import CmuxNextWakeups

/// Pairs a Chromium page's right-click with the page's report of what is under the pointer
/// (`cmuxAgentContextMenu`, ``AgentPaneView/receiveContextMenuReport(_:)``). WebKit asks for its
/// menu after the page's `contextmenu` handler posted the report; Chromium's menu request and the
/// page's message travel separately and arrive in either order, so the menu waits for the report,
/// at most ``limit``.
@MainActor
final class AgentPaneMenuReportWait {
    /// How long a menu waits for the report.
    let limit: Duration
    /// How recent a report that came before the menu must be to count for it.
    let freshness: Duration
    private let clock: any Clock<Duration>
    private var arrivedAt: ContinuousClock.Instant?
    /// Ends the waiting menu's report wait: a report, or the next menu.
    private var waiter: AsyncStream<Void>.Continuation?
    /// Bumped by each menu, so an older menu's end never clears a newer menu's ``waiter``.
    private var generation = 0

    /// - Parameters:
    ///   - limit: How long a menu waits for the report (default 250 ms: a report comes within a few
    ///     milliseconds, and a page that sends none still gets its menu).
    ///   - freshness: How recent an earlier report must be.
    ///   - clock: The timeout's clock (tests pass their own).
    init(limit: Duration = .milliseconds(250), freshness: Duration = .seconds(1), clock: any Clock<Duration> = ContinuousClock()) {
        self.limit = limit
        self.freshness = freshness
        self.clock = clock
    }

    /// The page's report arrived.
    func reported() {
        guard let waiter else {
            arrivedAt = .now
            return
        }
        self.waiter = nil
        waiter.finish()
    }

    /// Returns once the report for the menu about to open is in, or after ``limit``. The limit is
    /// a ``Deadline`` race: a flexible deadline with ``WakeLeeway``'s tolerance on the clock.
    func untilReported() async {
        if let arrivedAt, ContinuousClock.now - arrivedAt <= freshness {
            self.arrivedAt = nil
            return
        }
        arrivedAt = nil
        waiter?.finish()
        generation += 1
        let mine = generation
        let (report, arrived) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        waiter = arrived
        _ = await Deadline(limit, clock: clock).value("agent-pane.menu-report") {
            for await _ in report {}
        }
        // After the limit, this menu no longer waits: a later report counts for the next menu.
        if generation == mine { waiter = nil }
    }
}
