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
/// Each view that shows in a window reloads under a still picture of itself (``Cover``) that stays
/// until the new document has painted and its content stopped changing, then fades out (``Motion``'s pane fade): no
/// blank frames, the pane just changes.
@MainActor
final class WebBundleGracefulReload {
    /// The most times one cover asks the new document whether it settled (``settled(_:)``).
    static let settleAsks = 200

    /// How long a page has to answer whether it may reload now.
    static let answerWithin: Duration = .milliseconds(500)
    /// How often a held page is asked again.
    static let retry: Duration = .milliseconds(500)
    /// How long a page held only by what a reload disturbs (``disturbOnly``) waits before it reloads anyway.
    static let disturbLimit: Duration = .seconds(10)
    /// The longest a cover stays over a page that never settles.
    static let coverLimit: Duration = .milliseconds(2500)
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
    /// The covers shown now, by view: a second reload of a covered view keeps its first picture.
    private var covers: [ObjectIdentifier: Cover] = [:]
    /// Tests answer for the pages (nil: ask each page in its own world).
    var askOverride: (@MainActor ([WKWebView]) async -> [String?])?
    /// Tests reload without WebKit (nil: ``WebBundleServedViews/reload(_:to:)`` under a cover).
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
        let id = ObjectIdentifier(view)
        let tree = tree
        let served = served ?? .shared
        guard covers[id] == nil, Cover.shows(view) else {
            served.reload([view], to: tree)
            return
        }
        // task-owner: one cover's life: its picture, the reload under it, and its fade once the page settled
        Task { [weak self] in
            let cover = await Cover.make(over: view)
            guard let self else { return }
            guard let cover else {
                served.reload([view], to: tree)
                return
            }
            self.covers[id] = cover
            // The old document carries a mark in the app's own script world; the new one starts without it.
            await Self.run("window.cmuxSwapOld = true;", in: view, within: Self.answerWithin)
            served.reload([view], to: tree)
            await Self.settled(view)
            cover.fadeOut()
            if self.covers[id] === cover { self.covers[id] = nil }
        }
    }

    /// The new document's wait (in the app's script world): "old" while the old document still answers,
    /// else once it loaded and its content stopped changing for three frames in a row, at least one
    /// element (the transcript and the composer's draft drew, not the empty shell), or after `limit` ms.
    static let settleScript = """
        if (window.cmuxSwapOld) return "old";
        const start = performance.now();
        if (document.readyState !== "complete") {
            await new Promise((done) => { addEventListener("load", done, { once: true }); setTimeout(done, limit); });
        }
        await new Promise((done) => {
            let last = -1, same = 0;
            const tick = () => {
                const count = document.body ? document.body.getElementsByTagName("*").length : 0;
                same = count > 0 && count === last ? same + 1 : 0;
                last = count;
                if (same >= 3 || performance.now() - start > limit) return setTimeout(done, 0);
                requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
        });
        return "settled";
        """

    /// Returns once `view`'s new document loaded, painted and settled (``settleScript``), or after ``coverLimit``.
    static func settled(_ view: WKWebView) async {
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<settleAsks {
            let left = coverLimit - (clock.now - start)
            guard left > .zero else { return }
            let milliseconds = Int(left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000)
            let answer = await run(settleScript, in: view, arguments: ["limit": milliseconds], within: left)
            // The old document answered, or went away mid-answer: ask the new one a frame later.
            guard answer == "old" || answer == nil else { return }
            await pause(.milliseconds(16))
        }
    }

    /// Runs `script` in `view`'s app script world; its string answer, nil on an error or past `limit`.
    @discardableResult
    static func run(_ script: String, in view: WKWebView, arguments: [String: Any] = [:], within limit: Duration) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let once = Once(done)
            let deadline = DemandTimer(owner: "web-bundle.graceful-reload.script")
            deadline.schedule(after: limit) { @MainActor in once.resume(nil) }
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                deadline.cancel()
                if case .success(let value) = result { once.resume(value as? String) } else { once.resume(nil) }
            }
        }
    }

    /// Returns after `duration` (one DemandTimer).
    private static func pause(_ duration: Duration) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let timer = DemandTimer(owner: "web-bundle.graceful-reload.frame")
            timer.schedule(after: duration) { @MainActor in
                _ = timer
                done.resume()
            }
        }
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

    /// A still picture of a web view, over it in its superview, while the view reloads beneath.
    @MainActor final class Cover {
        private let image: NSImageView

        private init(image: NSImageView) { self.image = image }

        /// Whether `view` shows now: in a window, not hidden, with a size.
        static func shows(_ view: WKWebView) -> Bool {
            view.window != nil && view.superview != nil && !view.isHiddenOrHasHiddenAncestor && !view.bounds.isEmpty
        }

        /// A picture of `view` as it shows now, placed over it; nil when it has none or moved meanwhile.
        static func make(over view: WKWebView) async -> Cover? {
            let place = view.superview
            let frame = view.frame
            guard let picture = try? await view.takeSnapshot(configuration: nil),
                  let host = view.superview, host === place, view.frame == frame, shows(view) else { return nil }
            let image = NSImageView(frame: frame)
            image.image = picture
            image.imageScaling = .scaleAxesIndependently
            image.autoresizingMask = view.autoresizingMask
            image.wantsLayer = true
            host.addSubview(image, positioned: .above, relativeTo: view)
            return Cover(image: image)
        }

        func fadeOut() {
            let image = image
            Motion.panes.animate(.fadeOut, in: image, { image.animator().alphaValue = 0 }, completion: {
                image.removeFromSuperview()
            })
        }
    }
}
