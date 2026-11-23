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
/// a page without the hook reloads as before. The cover is ``PageWebView/snapshot()``.
@MainActor
final class PageGracefulReload {
    private var waiting: [ObjectIdentifier: (page: PageWebView, since: ContinuousClock.Instant)] = [:]
    private var generation: UInt64 = 0
    private var looking = false
    private let timer = DemandTimer(owner: "page.graceful-reload")
    private var covers: [ObjectIdentifier: NSImageView] = [:]
    /// Tests answer for the pages (nil: ask each page).
    var askOverride: (@MainActor ([PageWebView]) async -> [String?])?
    /// Tests reload without a page engine (nil: ``PageWebView/reload()`` under a cover).
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
        let id = ObjectIdentifier(page)
        guard covers[id] == nil, page.isShownForHealth, let host = page.superview else {
            page.reload()
            return
        }
        let frame = page.frame
        // task-owner: one cover's life: its picture, the reload under it, and its fade once the page settled
        Task { [weak self] in
            guard let picture = await page.snapshot(), let self,
                  page.superview === host, page.frame == frame, !page.isClosed else {
                page.reload()
                return
            }
            let cover = NSImageView(frame: frame)
            cover.image = picture
            cover.imageScaling = .scaleAxesIndependently
            cover.autoresizingMask = page.autoresizingMask
            cover.wantsLayer = true
            host.addSubview(cover, positioned: .above, relativeTo: page)
            self.covers[id] = cover
            _ = await page.callPageFunction("window.cmuxSwapOld = true; return null;", timeout: WebBundleGracefulReload.answerWithin)
            page.reload()
            await Self.settled(page)
            Motion.panes.animate(.fadeOut, in: cover, { cover.animator().alphaValue = 0 }, completion: {
                cover.removeFromSuperview()
            })
            if self.covers[id] === cover { self.covers[id] = nil }
        }
    }

    /// Returns once the new document settled (``WebBundleGracefulReload/settleScript``), or after the cover limit.
    private static func settled(_ page: PageWebView) async {
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<WebBundleGracefulReload.settleAsks {
            let left = WebBundleGracefulReload.coverLimit - (clock.now - start)
            guard left > .zero, !page.isClosed else { return }
            let milliseconds = Int(left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000)
            let answer = await page.callPageFunction(WebBundleGracefulReload.settleScript, arguments: ["limit": milliseconds], timeout: left) as? String
            if answer == "settled" { return }
            // The old document answered, or it went away mid-answer: ask the new one a frame later.
            await pause(.milliseconds(16))
        }
    }

    private static func pause(_ duration: Duration) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let timer = DemandTimer(owner: "page.graceful-reload.frame")
            timer.schedule(after: duration) { @MainActor in
                _ = timer
                done.resume()
            }
        }
    }
}
