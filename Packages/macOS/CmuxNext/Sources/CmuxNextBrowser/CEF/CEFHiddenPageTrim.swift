import CmuxNextWakeups
import Foundation
import os

/// Makes a kept hidden chat page cheaper without letting it go (CMUX-571, goal memory-per-chat). Leo, 2026-11-17:
/// "we cannot trade off instant loads. instant > memory", so a hidden chat keeps its page and its switch back draws
/// it at once; what goes is what Chromium can rebuild: its caches, and the frames and tiles of pages no one sees.
///
/// ``delay`` (10 s) after the newest hide of a cmux page, while a cmux page is still hidden, Chromium gets one
/// memory-pressure notice (`Memory.simulatePressureNotification`, ``level``) through one hidden page's DevTools
/// session, at most once per ``minimumGap``. A hide inside the wait moves it to 10 s after that hide, so a burst of
/// switches costs one round. Nothing is reloaded: every page keeps its DOM, scroll and state.
///
/// Chromium answers the notice in the browser process (content/browser/devtools/protocol/memory_handler.cc returns
/// Success, so no renderer gets the message; Blink has no handler, and RenderProcessHostImpl passes browser pressure
/// on to renderers only on Android and CastOS, and then to all of them): `MemoryPressureSource` runs every listener
/// of the whole browser process, synchronously, inside the shim's `SendDevToolsMessage`, on the main thread, and
/// each notice runs them all again. One notice per
/// hidden page made a round of N pages N process-wide purges in a row: 12 of the 17 NIGHTLY hangs in
/// `cmux_shim_devtools_call` of 2026-11-17/18 (2.1-4.6 s each, 2-5% CPU, page-ins) came from builds with that loop
/// (HQ #8689, #13672). So a round sends one notice, whatever the number of hidden pages.
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
    private let notify: @MainActor (CEFTab) async -> Bool
    private let now: () -> ContinuousClock.Instant
    private var lastNotice: ContinuousClock.Instant?
    /// Rounds sent (tests).
    private(set) var notices = 0

    init(now: @escaping () -> ContinuousClock.Instant = { .now }, hiddenPages: @escaping @MainActor () -> [CEFTab],
         notify: @escaping @MainActor (CEFTab) async -> Bool) {
        self.now = now
        self.hiddenPages = hiddenPages
        self.notify = notify
    }

    /// A cmux page hid: the round goes out ``nextDelay(since:now:)`` from now (each hide moves it).
    func pageHidden() {
        timer.schedule(after: Self.nextDelay(since: lastNotice, now: now())) { @MainActor [weak self] in await self?.trim() }
    }

    /// The notice itself, through `tab`'s DevTools. False when it did not reach Chromium or got no answer (the page
    /// closed meanwhile).
    static func notice(_ tab: CEFTab) async -> Bool {
        (try? await tab.devTools(method: "Memory.simulatePressureNotification", params: ["level": level], timeout: .seconds(10))) != nil
    }

    /// Sends the notice once, through the first cmux page hidden now, or the next when it could not take it (a page
    /// closing); none when none is hidden.
    func trim() async {
        let pages = hiddenPages()
        guard !pages.isEmpty else { return }
        lastNotice = now()
        notices += 1
        // Notice, not info: the field log keeps it (the bench reads it to see the round ran).
        logger.notice("hidden page trim: pressure notice (one) for \(pages.count, privacy: .public) hidden cmux pages")
        for page in pages {
            if await notify(page) { return }
        }
    }

    /// ``delay``, or longer when the last round was less than ``minimumGap`` before `now`.
    nonisolated static func nextDelay(since last: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Duration {
        guard let last else { return delay }
        return max(delay, minimumGap - (now - last))
    }
}
