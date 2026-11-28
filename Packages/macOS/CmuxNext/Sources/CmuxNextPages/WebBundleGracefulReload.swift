import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import WebKit

/// How a change of the web layer (a customization put on or off, `cmux customize use`, the dev
/// server, cmux Live) reaches the open agent panes and pages: gracefully, each page at its own safe
/// point and under a picture of itself, so the change just appears (Leo, 2026-11-22: "we need to have
/// far more graceful reloads that appear to just be instantly gracefully transitioned. my composer is
/// ideally untouched as much as possible. likewise with my drafts" and "it's a graceful if not
/// imperceptible state transition all around").
///
/// One per ``WebDevOverrideWatcher`` (its `gracefulReload`). Until now ``WebDevOverrideWatcher/reloadPages(live:hosting:pages:served:watcher:)`` reloaded every
/// served view at once: each pane went blank for a few frames, the one being typed in lost its focus
/// and caret, and a field the page does not keep lost its text. A web update already waited for each
/// page's own answer (`window.cmuxWebSwap.hold()`, webviews/src/pages/shared/webSwap.ts, the safe point
/// in plans/cmux-next/web-ota.md); a layer change now asks the same:
///
/// - A page that answers null reloads now. The answer also stashes which part had the keyboard
///   (the composer), so it gets it back with its draft once the page is up again.
/// - A page that answers why not waits, asked again every ``retry``. Past ``disturbLimit`` a page held
///   only by what a reload moves but does not lose (scroll, caret, focus, an open menu, a selection)
///   reloads anyway: the change the person asked for shows. One held by text or input that would be
///   lost (a field the page does not keep, an input method composing, a send on the way) waits until
///   that is done, however long.
/// - A page without the hook, or one that does not answer within ``answerWithin``, reloads now, as
///   every page did before.
///
/// Each view then swaps in place (``WebBundleServedViews/swapReload(_:)``): its document hands its
/// state over, a still of its last frame covers it, and the new document shows itself in one frame
/// once it is the page it was (draft, caret, chips, scroll): no blank frames, no fade, the pane just
/// changes.
@MainActor
final class WebBundleGracefulReload {
    /// How long a page has to answer whether it may reload now.
    static let answerWithin: Duration = .milliseconds(500)
    /// How often a held page is asked again.
    static let retry: Duration = .milliseconds(500)
    /// How long a page held only by what a reload disturbs (``disturbOnly``) waits before it reloads anyway.
    static let disturbLimit: Duration = .seconds(10)
    /// Hold reasons (``webSwapHold`` in webviews/src/pages/shared/webSwap.ts) that a reload only
    /// disturbs: the page comes back, without that scroll, caret, focus, menu or selection.
    static let disturbOnly: Set<String> = ["scroll", "caret", "focus", "popup", "selection", "page.loading"]

    /// The views waiting for their safe point, and the tree each reloads into.
    private var waiting: [ObjectIdentifier: (view: WKWebView, since: ContinuousClock.Instant)] = [:]
    private var tree: URL?
    private weak var served: WebBundleServedViews?
    private var generation: UInt64 = 0
    private var looking = false
    private let timer = DemandTimer(owner: "web-bundle.graceful-reload")
    /// Tests answer for the pages (nil: ask each page in its own world).
    var askOverride: (@MainActor ([WKWebView]) async -> [String?])?
    /// Tests reload without WebKit (nil: ``WebBundleServedViews/reload(_:to:)``, a swap in place).
    var reloadOverride: (@MainActor (WKWebView) -> Void)?
    /// Tests run each look themselves (false: nothing is booked).
    var booksLooks = true

    /// Reloads `views` from `tree` (nil: the bundle) through `served`, each at its safe point. A later
    /// call replaces the views still waiting from an earlier one.
    func reload(_ views: [WKWebView], to tree: URL?, served: WebBundleServedViews) {
        generation &+= 1
        self.tree = tree
        self.served = served
        let now = ContinuousClock.now
        var next: [ObjectIdentifier: (view: WKWebView, since: ContinuousClock.Instant)] = [:]
        for view in views {
            let id = ObjectIdentifier(view)
            // A view still waiting from the last change keeps the time it started waiting.
            next[id] = (view, waiting[id]?.since ?? now)
        }
        waiting = next
        guard !waiting.isEmpty else { return timer.cancel() }
        book(.zero)
    }

    /// How many views still wait for their safe point (tests).
    var waitingCount: Int { waiting.count }

    /// Asks every waiting view, reloads the ones that may, and books the next look for the rest.
    func look() async {
        guard !looking, !waiting.isEmpty else { return }
        looking = true
        defer { looking = false }
        let generation = generation
        let entries = Array(waiting.values)
        let views = entries.map(\.view)
        let answers = await ask(views)
        // A newer change came while the pages answered: its own look decides.
        guard generation == self.generation else { return }
        let now = ContinuousClock.now
        for (entry, answer) in zip(entries, answers) {
            let id = ObjectIdentifier(entry.view)
            guard waiting[id] != nil else { continue }
            guard Self.mayReload(answer, waited: now - entry.since) else { continue }
            waiting[id] = nil
            reloadNow(entry.view)
        }
        guard !waiting.isEmpty else { return }
        book(Self.retry)
    }

    private func book(_ after: Duration) {
        guard booksLooks else { return }
        timer.schedule(after: after) { @MainActor [weak self] in await self?.look() }
    }

    /// Whether a page that answered `answer` after waiting `waited` reloads now.
    static func mayReload(_ answer: String?, waited: Duration) -> Bool {
        guard let answer else { return true }
        // No hook, a page error or no answer: the page keeps nothing it told us about; it reloads as before.
        if answer == "page.no-hook" || answer == "page.error" || answer == "page.no-answer" { return true }
        return waited >= disturbLimit && disturbOnly.contains(answer)
    }

    private func ask(_ views: [WKWebView]) async -> [String?] {
        if let askOverride { return await askOverride(views) }
        // All pages are asked at once; each answer is bounded by answerWithin.
        // task-owner: one page's answer each, awaited below
        let asks = views.map { view in Task { await Self.askPage(view) } }
        var answers: [String?] = []
        for ask in asks { answers.append(await ask.value) }
        return answers
    }

    /// The page's answer to `window.cmuxWebSwap.hold()` (nil: it may reload now), or why not.
    private static func askPage(_ view: WKWebView) async -> String? {
        guard view.url != nil else { return nil }
        if view.isLoading { return "page.loading" }
        let script = """
        const swap = window.cmuxWebSwap;
        if (!swap || typeof swap.hold !== "function") return "page.no-hook";
        const held = await swap.hold();
        return typeof held === "string" && held ? held : null;
        """
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let once = Once(done)
            let deadline = DemandTimer(owner: "web-bundle.graceful-reload.answer")
            deadline.schedule(after: answerWithin) { @MainActor in once.resume("page.no-answer") }
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                deadline.cancel()
                switch result {
                case .success(let value): once.resume((value as? String).flatMap { $0.isEmpty ? nil : $0 })
                case .failure: once.resume("page.error")
                }
            }
        }
    }

    private func reloadNow(_ view: WKWebView) {
        if let reloadOverride { return reloadOverride(view) }
        // In place with no visible reload: the page hands its state over and shows itself again under a
        // still of its last frame only once it is the page it was (WebBundleServedViews.swapReload,
        // WebViewSwap.swift, PageWebView+GracefulSwap.swift).
        (served ?? .shared).reload([view], to: tree)
    }

    /// Resumes a continuation once, from the page's answer or the deadline, whichever comes first.
    @MainActor private final class Once {
        private var done: CheckedContinuation<String?, Never>?
        init(_ done: CheckedContinuation<String?, Never>) { self.done = done }
        func resume(_ value: String?) {
            done?.resume(returning: value)
            done = nil
        }
    }
}
