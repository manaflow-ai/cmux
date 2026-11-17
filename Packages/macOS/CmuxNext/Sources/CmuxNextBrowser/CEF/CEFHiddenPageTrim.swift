import CmuxNextWakeups
import Foundation
import os

/// Makes a kept hidden chat page cheaper without letting it go (CMUX-571, goal memory-per-chat). Leo, 2026-11-17:
/// "we cannot trade off instant loads. instant > memory", so a hidden chat keeps its page and its switch back draws
/// it at once; what goes is what Chromium can rebuild: its caches, and the frames and tiles of pages no one sees.
///
/// ``delay`` (10 s) after the newest hide of a cmux page, every cmux page still hidden gets a memory-pressure notice
/// (`Memory.simulatePressureNotification`, ``level``) through its own DevTools session, at most once per
/// ``minimumGap``. A hide inside the wait moves it to 10 s after that hide, so a burst of switches costs one round.
/// Each notice reaches that page's renderer: V8 collects and shrinks its heap, Blink drops decoded images, fonts and
/// resources it can read again. Nothing is reloaded: every page keeps its DOM, scroll and state.
@MainActor
final class CEFHiddenPageTrim {
    /// Chromium's pressure level the notice names.
    nonisolated static let level = "critical"
    /// From the newest hide to the notice.
    nonisolated static let delay: Duration = .seconds(10)
    /// The least time between two rounds.
    nonisolated static let minimumGap: Duration = .seconds(60)

    private let timer = DemandTimer(owner: "CEFHiddenPageTrim")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef.hidden-page-trim")
    /// The cmux pages hidden now (the runtime's open tabs).
    private let hiddenPages: @MainActor () -> [CEFTab]
    private let notify: @MainActor (CEFTab) async -> Void
    private let now: () -> ContinuousClock.Instant
    private var lastNotice: ContinuousClock.Instant?
    /// Rounds sent (tests).
    private(set) var notices = 0

    init(now: @escaping () -> ContinuousClock.Instant = { .now }, hiddenPages: @escaping @MainActor () -> [CEFTab],
         notify: @escaping @MainActor (CEFTab) async -> Void) {
        self.now = now
        self.hiddenPages = hiddenPages
        self.notify = notify
    }

    /// A cmux page hid: the round goes out ``nextDelay(since:now:)`` from now (each hide moves it).
    func pageHidden() {
        timer.schedule(after: Self.nextDelay(since: lastNotice, now: now())) { @MainActor [weak self] in await self?.trim() }
    }

    /// The notice itself, through `tab`'s DevTools.
    static func notice(_ tab: CEFTab) async {
        _ = try? await tab.devTools(method: "Memory.simulatePressureNotification", params: ["level": level], timeout: .seconds(10))
    }

    /// Sends the notice to every cmux page hidden now; none when none is.
    func trim() async {
        let pages = hiddenPages()
        guard !pages.isEmpty else { return }
        lastNotice = now()
        notices += 1
        // Notice, not info: the field log keeps it (the bench reads it to see the round ran).
        logger.notice("hidden page trim: pressure notice to \(pages.count, privacy: .public) hidden cmux pages")
        for page in pages { await notify(page) }
    }

    /// ``delay``, or longer when the last round was less than ``minimumGap`` before `now`.
    nonisolated static func nextDelay(since last: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Duration {
        guard let last else { return delay }
        return max(delay, minimumGap - (now - last))
    }
}
