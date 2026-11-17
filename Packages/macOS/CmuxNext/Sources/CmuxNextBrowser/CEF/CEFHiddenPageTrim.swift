import CmuxNextWakeups
import Foundation

/// Makes a kept hidden chat page cheaper without letting it go (CMUX-571, goal memory-per-chat). Leo, 2026-11-17:
/// "we cannot trade off instant loads. instant > memory", so a hidden chat keeps its page and its switch back draws
/// it at once; what goes is what Chromium can rebuild: its caches, and the frames and tiles of pages no one sees.
///
/// ``delay`` (10 s) after the newest hide of a cmux page, while a cmux page is still hidden, Chromium gets one
/// memory-pressure notice (`Memory.simulatePressureNotification`, ``level``), at most one per ``minimumGap``. A hide
/// inside the wait moves it to 10 s after that hide, so a burst of switches costs one notice. The notice reaches the
/// browser and every renderer: V8 collects and shrinks its heap, Blink drops decoded images, fonts and resources it
/// can read again, and the browser evicts the saved frames of hidden pages. Nothing is reloaded: every page keeps
/// its DOM, scroll and state.
@MainActor
final class CEFHiddenPageTrim {
    /// Chromium's pressure level the notice names.
    nonisolated static let level = "critical"
    /// From the newest hide to the notice.
    nonisolated static let delay: Duration = .seconds(10)
    /// The least time between two notices.
    nonisolated static let minimumGap: Duration = .seconds(60)

    private let timer = DemandTimer(owner: "CEFHiddenPageTrim")
    private let notify: @MainActor (CEFTab) async -> Void
    private let now: () -> ContinuousClock.Instant
    /// The page the next notice goes through: the newest hidden one.
    private weak var target: CEFTab?
    private var lastNotice: ContinuousClock.Instant?
    /// Notices sent (tests).
    private(set) var notices = 0

    init(now: @escaping () -> ContinuousClock.Instant = { .now }, notify: @escaping @MainActor (CEFTab) async -> Void) {
        self.now = now
        self.notify = notify
    }

    /// A cmux page hid: the notice goes out ``nextDelay(since:now:)`` from now (each hide moves it).
    func pageHidden(_ tab: CEFTab) {
        target = tab
        timer.schedule(after: Self.nextDelay(since: lastNotice, now: now())) { @MainActor [weak self] in await self?.trim() }
    }

    /// The notice itself, through `tab`'s DevTools (the runtime's `hiddenPageTrim` sends it).
    static func notice(_ tab: CEFTab) async {
        _ = try? await tab.devTools(method: "Memory.simulatePressureNotification", params: ["level": level], timeout: .seconds(10))
    }

    /// Sends the notice through the newest hidden page, when it is still open and still hidden.
    func trim() async {
        guard let tab = target, !tab.isClosed, tab.isContentHidden else { return }
        target = nil
        lastNotice = now()
        notices += 1
        await notify(tab)
    }

    /// ``delay``, or longer when the last notice was less than ``minimumGap`` before `now`.
    nonisolated static func nextDelay(since last: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Duration {
        guard let last else { return delay }
        return max(delay, minimumGap - (now - last))
    }
}
