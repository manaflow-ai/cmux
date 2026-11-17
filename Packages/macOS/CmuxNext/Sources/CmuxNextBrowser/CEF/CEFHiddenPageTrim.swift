import CmuxNextWakeups
import Foundation

/// Makes a kept hidden chat page cheaper without letting it go (CMUX-571, goal memory-per-chat). Leo, 2026-11-17:
/// "we cannot trade off instant loads. instant > memory", so a hidden chat keeps its page and its switch back draws
/// it at once; what goes is what Chromium can rebuild: its caches, and the frames and tiles of pages no one sees.
///
/// When a cmux page freezes (hidden `browser.freezeHiddenTabs` seconds, 30 by default: ``CEFTab/setFrozen(_:)``),
/// Chromium gets one memory-pressure notice (`Memory.simulatePressureNotification`, ``level``), ``delay`` after the
/// first freeze of a burst and at most once per ``minimumGap``. The notice reaches the browser and every renderer:
/// V8 collects and shrinks its heap, Blink drops decoded images, fonts and resources it can read again, and the
/// browser evicts the saved frames of hidden pages. Nothing is reloaded: the page keeps its DOM, scroll and state.
/// A chat looked at again within the freeze wait is never touched.
@MainActor
final class CEFHiddenPageTrim {
    /// The app's one trim (every cmux page shares the runtime).
    static let shared = CEFHiddenPageTrim { tab in
        _ = try? await tab.devTools(method: "Memory.simulatePressureNotification", params: ["level": CEFHiddenPageTrim.level], timeout: .seconds(10))
    }

    /// Chromium's pressure level the notice names.
    static let level = "critical"
    /// From the first freeze of a burst to the notice: one notice serves every page frozen together.
    static let delay: Duration = .seconds(2)
    /// The least time between two notices.
    static let minimumGap: Duration = .seconds(60)

    private let timer = DemandTimer(owner: "CEFHiddenPageTrim")
    private let notify: @MainActor (CEFTab) async -> Void
    private let now: () -> ContinuousClock.Instant
    /// The page the next notice goes through: the newest frozen one still open.
    private weak var target: CEFTab?
    private var lastNotice: ContinuousClock.Instant?
    /// Notices sent (tests).
    private(set) var notices = 0

    init(now: @escaping () -> ContinuousClock.Instant = { .now }, notify: @escaping @MainActor (CEFTab) async -> Void) {
        self.now = now
        self.notify = notify
    }

    /// A cmux page froze: a notice goes out within ``wait(since:now:)``.
    func pageFroze(_ tab: CEFTab) {
        target = tab
        timer.scheduleIfIdle(after: Self.wait(since: lastNotice, now: now())) { @MainActor [weak self] in await self?.trim() }
    }

    /// Sends the notice through the newest frozen page, when it is still open.
    func trim() async {
        guard let tab = target, !tab.isClosed else { return }
        target = nil
        lastNotice = now()
        notices += 1
        await notify(tab)
    }

    /// ``delay``, or longer when the last notice was less than ``minimumGap`` before `now`.
    nonisolated static func wait(since last: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Duration {
        guard let last else { return delay }
        return max(delay, minimumGap - (now - last))
    }
}
