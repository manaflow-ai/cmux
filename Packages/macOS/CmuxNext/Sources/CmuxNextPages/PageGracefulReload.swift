import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import Foundation

/// The Chromium half of a graceful web layer change: each open page that Chromium shows reloads at its
/// own safe point, under a picture of itself, as ``WebBundleGracefulReload`` does for the WebKit views
/// the scheme handlers served (Leo, 2026-11-22: "it's a graceful if not imperceptible state transition
/// all around"). Before this, ``WebDevOverrideWatcher/reloadPages(live:hosting:pages:served:watcher:)``
/// reloaded every Chromium page at once (`page.reload()`): an agent chat on Chromium went blank, and
/// its composer lost the keyboard.
///
/// The same rules as the WebKit half, the same constants: a page asked through
/// ``PageWebView/callPageFunction(_:arguments:timeout:)`` (either engine) answers
/// `window.cmuxWebSwap.hold()`; null reloads now, a reason waits (``WebBundleGracefulReload/mayReload(_:waited:)``),
/// a page without the hook reloads as before. A page that may reloads in place (``PageWebView/swapReload()``).
@MainActor
final class PageGracefulReload {
    private var waiting: [ObjectIdentifier: (page: PageWebView, since: ContinuousClock.Instant)] = [:]
    private var generation: UInt64 = 0
    private var looking = false
    private let timer = DemandTimer(owner: "page.graceful-reload")
    /// Tests answer for the pages (nil: ask each page).
    var askOverride: (@MainActor ([PageWebView]) async -> [String?])?
    /// Tests reload without a page engine (nil: ``PageWebView/swapReload()``).
    var reloadOverride: (@MainActor (PageWebView) -> Void)?
    /// Tests run each look themselves (false: nothing is booked).
    var booksLooks = true

    /// Reloads `pages`, each at its safe point. A later call replaces the pages still waiting.
    /// - Returns: The first look (tests wait on it), nil when no page waits.
    @discardableResult
    func reload(_ pages: [PageWebView]) -> Task<Void, Never>? {
        generation &+= 1
        let now = ContinuousClock.now
        var next: [ObjectIdentifier: (page: PageWebView, since: ContinuousClock.Instant)] = [:]
        for page in pages {
            let id = ObjectIdentifier(page)
            next[id] = (page, waiting[id]?.since ?? now)
        }
        waiting = next
        guard !waiting.isEmpty else {
            timer.cancel()
            return nil
        }
        guard booksLooks else { return nil }
        // task-owner: the first look at these pages; later ones are booked on the timer
        return Task { [weak self] in await self?.look() }
    }

    /// Reloads `page` now, under a picture of itself: the person asked, so no safe point is waited for
    /// (their draft was saved first). A page out of sight, or one whose picture fails, reloads bare.
    func reloadUnderCover(_ page: PageWebView) {
        guard !page.isClosed else { return }
        reloadNow(page)
    }

    /// How many pages still wait for their safe point (tests).
    var waitingCount: Int { waiting.count }

    /// Asks every waiting page, reloads the ones that may, and books the next look for the rest.
    func look() async {
        guard !looking, !waiting.isEmpty else { return }
        looking = true
        defer { looking = false }
        let generation = generation
        let entries = Array(waiting.values)
        let answers = await ask(entries.map(\.page))
        guard generation == self.generation else { return }
        let now = ContinuousClock.now
        for (entry, answer) in zip(entries, answers) {
            let id = ObjectIdentifier(entry.page)
            guard waiting[id] != nil else { continue }
            // A page closed while it waited has nothing left to reload.
            if entry.page.isClosed {
                waiting[id] = nil
                continue
            }
            guard WebBundleGracefulReload.mayReload(answer, waited: now - entry.since) else { continue }
            waiting[id] = nil
            reloadNow(entry.page)
        }
        guard !waiting.isEmpty else { return }
        book(WebBundleGracefulReload.retry)
    }

    private func book(_ after: Duration) {
        guard booksLooks else { return }
        timer.schedule(after: after) { @MainActor [weak self] in await self?.look() }
    }

    private func ask(_ pages: [PageWebView]) async -> [String?] {
        if let askOverride { return await askOverride(pages) }
        // task-owner: one page's answer each, awaited below
        let asks = pages.map { page in Task { await Self.askPage(page) } }
        var answers: [String?] = []
        for ask in asks { answers.append(await ask.value) }
        return answers
    }

    /// The page's answer to `window.cmuxWebSwap.hold()` (nil: it may reload now), or why not.
    private static func askPage(_ page: PageWebView) async -> String? {
        guard !page.isClosed else { return nil }
        if !page.loaded { return "page.loading" }
        let script = """
        const swap = window.cmuxWebSwap;
        if (!swap || typeof swap.hold !== "function") return "page.no-hook";
        const held = await swap.hold();
        return typeof held === "string" && held ? held : "";
        """
        // callPageFunction answers nil for an exception, no page or no answer in time: reload as before.
        guard let answer = await page.callPageFunction(script, timeout: WebBundleGracefulReload.answerWithin) as? String else {
            return "page.no-answer"
        }
        return answer.isEmpty ? nil : answer
    }

    private func reloadNow(_ page: PageWebView) {
        if let reloadOverride { return reloadOverride(page) }
        // task-owner: one swap per page; it ends with the page's restored frame or its cover limit
        Task { await page.swapReload() }
    }
}
