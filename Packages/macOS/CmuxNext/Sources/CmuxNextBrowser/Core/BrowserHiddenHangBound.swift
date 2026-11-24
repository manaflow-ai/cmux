import CmuxNextWakeups
import os

/// Ends the renderer of a hidden page that stays hung (hq#13463).
///
/// When a renderer stops answering, Chromium's hang monitor reports it (`renderUnresponsive`) and the
/// page shows "Page unresponsive" with Wait and Exit. A shown page leaves that choice to the person.
/// A hidden page has no visible card, so nobody can answer it: the page stayed hung until the app quit,
/// and every agent call to it (DevTools, evaluate, screenshot) ran into its timeout again and again.
///
/// This puts a bound on that wait. While a page is hung and hidden, it waits ``limit``. If the page is
/// still hung and still hidden then, and no shown page shares its renderer, ``end`` ends the renderer.
/// The tab then owes one automatic reload, taken when it is next shown (``BrowserExitRecovery/endedForHang(now:)``).
/// A page that answers again, is shown, closes or loses its renderer before then cancels the bound.
@MainActor
final class BrowserHiddenHangBound {
    /// How long a hidden page that Chromium already reports hung waits before its renderer is ended.
    /// Chromium reports a hang only after its own timer ran out (about 15 s with no answer).
    static let limit: Duration = .seconds(10)

    private let timer: DemandTimer
    private let limit: Duration
    /// Whether the renderer may be ended now (no shown page shares it).
    private let mayEnd: @MainActor () -> Bool
    private let end: @MainActor () -> Void
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser")
    /// Renderers this bound ended (tests, `debug.browser`).
    private(set) var ends = 0

    init(owner: String, clock: any Clock<Duration> = ContinuousClock(), limit: Duration = BrowserHiddenHangBound.limit,
         mayEnd: @escaping @MainActor () -> Bool, end: @escaping @MainActor () -> Void) {
        timer = DemandTimer(owner: owner, clock: clock)
        self.limit = limit
        self.mayEnd = mayEnd
        self.end = end
    }

    /// Whether an end waits for the limit now.
    var isPending: Bool { timer.isScheduled }

    /// The page's hang state or visibility changed. Arms the bound when the page is hung and hidden;
    /// otherwise cancels it.
    func update(unresponsive: Bool, shown: Bool) {
        guard unresponsive, !shown else { return timer.cancel() }
        guard !timer.isScheduled else { return }
        // wakeup-allow: one bound on a hidden page Chromium reports hung; cancelled when it answers, shows or closes.
        timer.schedule(after: limit) { @MainActor [weak self] in self?.limitReached() }
    }

    /// The page closed or its renderer ended: nothing waits.
    func cancel() { timer.cancel() }

    private func limitReached() {
        guard mayEnd() else { return }
        ends += 1
        Self.logger.error("hidden page unresponsive for \(self.limit, privacy: .public) after the hang report; ending its renderer")
        end()
    }
}
