import AppKit
package import CmuxNextPages
import CmuxNextUpdater
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import CoreGraphics

// The safe point (plans/cmux-next/web-ota.md, ``WebSwapGate``). While an update is pending or a
// shown page waits to reload, one DemandTimer (`web-updates.safe-point`) books the next look; a look
// either swaps (or reloads those pages) or books the next one. It stops when nothing waits: a swap
// (here or `updates.web.apply`) cancels it, and a look that finds nothing waiting books none. Each
// look asks the pages the swap reloads now (``WebBundleHost/bundleAskedPages``, the WebKit pages the
// update folder serves; twice), in the page's own world, through `window.cmuxWebSwap.hold()`
// (webviews/src/pages/shared/webSwap.ts), and never waits on a page past ``WebSwapGate/answerWithin``. With feature `webUpdateReloadOnShow` those
// are the shown pages only: a hidden or frozen page is never asked, so it never holds the swap; it
// keeps its document, which loads its lazy chunks from its own files (``WebBundleOverlay/Pin``). As
// it shows it is asked at once and reloads when it answers null; else it stays stale and the same
// looks, under the same rules, ask it until it allows the reload (``askShownStale()``, p13-webui.md 3.C).
extension WebUpdates: WebBundleSafePoint {
    /// The pages the swap reloads now (``WebBundleHost/bundleAskedPages``); none before the host exists.
    var askedPages: [any WebBundlePage] { pages()?.bundleAskedPages ?? [] }

    /// The pages that show with files a swap replaced (``WebBundleHost/staleShownPages``).
    var staleShownPages: [any WebBundlePage] { pages()?.staleShownPages ?? [] }

    /// What a look asks: the pages the pending swap reloads, else the shown pages still on replaced files.
    var lookPages: [any WebBundlePage] { pending != nil ? askedPages : staleShownPages }

    /// A look has work: an update is pending, or a shown page still waits to reload.
    var hasLookWork: Bool { pending != nil || !staleShownPages.isEmpty }

    /// `page` shows with files a swap replaced: the safe point's next look runs now and asks the shown
    /// stale pages (``askShownStale()``). A pending swap asks and reloads it at its own look.
    package func staleShown(_ page: any WebBundlePage) {
        guard pending == nil else { return }
        safePoint.schedule(after: .zero) { @MainActor [weak self] in await self?.askShownStale() }
    }

    /// Asks the pages that show with files a swap replaced, as they show, whether a reload keeps all
    /// they hold: each that says so, and still shows the same idle stale document, reloads; any other
    /// stays stale, and the next look asks it again under ``WebSwapGate``'s rules.
    func askShownStale() async {
        guard pending == nil else { return }
        let asked = staleShownPages
        guard !asked.isEmpty else { return scheduleSafePoint() }
        let documents = asked.map(\.bundleDocument)
        let answers = await Self.askAll(asked)
        // A swap now pending asks every shown page at its own look.
        guard pending == nil else { return }
        var held: String?
        for (index, page) in asked.enumerated() where page.bundleStale && page.bundleShown {
            if answers[index] == nil, !page.bundleLoading, page.bundleDocument == documents[index] {
                page.reloadForBundle()
            } else {
                held = held ?? answers[index] ?? "page.changed"
            }
        }
        heldBy = held
        scheduleSafePoint()
    }

    /// Books the next look: at once while no page would reload, after ``WebSwapGate/grace`` behind other
    /// apps, else when the input quiet period could end. Replaces a booked look.
    func scheduleSafePoint() {
        guard hasLookWork else { return safePoint.cancel() }
        let wait: Duration = if lookPages.isEmpty {
            .zero
        } else if NSApp?.isActive ?? false {
            .milliseconds(Int(max(0, WebSwapGate.seconds(WebSwapGate.quietInput) - Self.idleSeconds()) * 1000))
        } else {
            WebSwapGate.grace
        }
        safePoint.schedule(after: wait) { @MainActor [weak self] in await self?.look() }
    }

    /// Swaps when the app and every page the swap reloads allow it, else books the next look. Those
    /// pages are asked twice, all at once each time; the second pass and the checks after it run right
    /// before the swap, so a page that got busy (or started loading) after its first answer holds it.
    /// With no update pending, the shown pages still on replaced files are asked the same way and
    /// reload when they allow it.
    func look() async {
        guard hasLookWork, !looking else { return }
        looking = true
        defer { looking = false }
        let generation = pendingGeneration
        let swaps = pending != nil
        var decision = appDecision()
        if decision == .askPages {
            let asked = lookPages
            let documents = asked.map(\.bundleDocument)
            decision = WebSwapGate.pages(await Self.askAll(asked))
            if decision == .swap { decision = WebSwapGate.pages(await Self.askAll(asked)) }
            // A page that came up, navigated or started loading while the pages answered was not
            // asked about what it shows now: it is asked next time.
            if decision == .swap,
               Set(lookPages.map { ObjectIdentifier($0) }) != Set(asked.map { ObjectIdentifier($0) })
               || asked.map(\.bundleDocument) != documents || asked.contains(where: \.bundleLoading) {
                decision = .later(after: .seconds(1), reason: "page.changed")
            }
            // Input, a sheet or a switch away that came while the pages answered still holds it.
            if decision == .swap {
                let again = appDecision()
                if case .later = again { decision = again }
            }
        }
        guard hasLookWork else { return }
        // Another update was handed over, or one swapped, while the pages answered: look again.
        if generation != pendingGeneration || swaps != (pending != nil) {
            decision = .later(after: .zero, reason: "update.new")
        }
        switch decision {
        case .swap, .askPages:
            if swaps { applyPending() } else { reloadStaleShown() }
        case .later(let after, let reason):
            heldBy = reason
            safePoint.schedule(after: after) { @MainActor [weak self] in await self?.look() }
        }
    }

    /// Reloads the shown pages still on files a swap replaced, which allowed it at this look.
    private func reloadStaleShown() {
        heldBy = nil
        safePoint.cancel()
        for page in staleShownPages { page.reloadForBundle() }
    }

    private func appDecision() -> WebSwapGate.Decision {
        let pagesShown = !lookPages.isEmpty
        if let appGate { return appGate(pagesShown) }
        let away = resignedAt.map { WebSwapGate.seconds(.now - $0) } ?? .infinity
        return WebSwapGate.app(pagesShown: pagesShown, active: NSApp?.isActive ?? false,
                               idle: Self.idleSeconds(), blocked: Self.appBlocked(), away: away)
    }

    /// What modal the app has open: a modal window, a sheet, a menu or drag being tracked.
    static func appBlocked() -> String? {
        if NSApp.modalWindow != nil { return "app.modal" }
        if NSApp.windows.contains(where: { $0.attachedSheet != nil }) { return "app.sheet" }
        if RunLoop.current.currentMode == .eventTracking { return "app.tracking" }
        return nil
    }

    /// Seconds since the last keyboard, pointer, scroll or click event in the login session.
    static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .scrollWheel, .leftMouseDown,
                                    .rightMouseDown, .otherMouseDown, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    /// Each page's answer, in order: nil when a reload keeps all it holds, else why not. All pages
    /// are asked at once; a page still loading, without the hook, failing or silent past
    /// ``WebSwapGate/answerWithin`` (one deadline for all) is busy.
    static func askAll(_ pages: [any WebBundlePage]) async -> [String?] {
        guard !pages.isEmpty else { return [] }
        // Answers dropped before they resumed read as no page answering.
        let unanswered = [String?](repeating: "page.no-answer", count: pages.count)
        return (try? await withOnceContinuation { (done: OnceContinuation<[String?], OnceContinuationError>) in
            let answers = Answers(count: pages.count, done)
            let deadline = DemandTimer(owner: "web-updates.page-answer")
            answers.deadline = deadline
            deadline.scheduleOnMain(after: WebSwapGate.answerWithin) { answers.finish() }
            for (index, page) in pages.enumerated() {
                if page.bundleLoading {
                    answers.set(index, "page.loading")
                    continue
                }
                ask(page, index: index, into: answers)
            }
        }) ?? unanswered
    }

    /// Asks `page` from a task off the main actor: only the page's own call and the answer's record run
    /// there (p06-scheduler.md recipe R-hop, the async form).
    private nonisolated static func ask(_ page: any WebBundlePage, index: Int, into answers: Answers) {
        // task-owner: one page's answer; the deadline answers for it when it is late
        Task { await answers.set(index, await page.askBundleSwap()) }
    }

    /// The pages' answers for one ask: resumes once, when every page answered or at the deadline
    /// (an unanswered page reads `page.no-answer`), and cancels the deadline then.
    @MainActor private final class Answers {
        private var values: [String??]
        private var left: Int
        private var done: OnceContinuation<[String?], OnceContinuationError>?
        var deadline: DemandTimer?

        init(count: Int, _ done: OnceContinuation<[String?], OnceContinuationError>) {
            values = Array(repeating: nil, count: count)
            left = count
            self.done = done
        }

        func set(_ index: Int, _ value: String?) {
            guard done != nil, values[index] == nil else { return }
            values[index] = .some(value)
            left -= 1
            if left == 0 { finish() }
        }

        func finish() {
            deadline?.cancel()
            deadline = nil
            done?.resume(returning: values.map { $0 ?? "page.no-answer" })
            done = nil
        }
    }
}
