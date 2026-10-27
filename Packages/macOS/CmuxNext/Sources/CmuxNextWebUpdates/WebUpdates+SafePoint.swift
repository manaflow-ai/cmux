import AppKit
import CmuxNextPages
import CmuxNextUpdater
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import CoreGraphics

// The safe point (plans/cmux-next/web-ota.md, ``WebSwapGate``). While an update is pending, one
// DemandTimer (`web-updates.safe-point`) books the next look; a look either swaps or books the
// next one. It stops when nothing is pending: a swap (here or `updates.web.apply`) cancels it, and
// a look that finds nothing pending books none. Each look asks the pages the page host shows now
// (``WebBundleHost/shownBundlePages``, both engines; twice), in the page's own world, through
// `window.cmuxWebSwap.hold()` (webviews/src/pages/shared/webSwap.ts), and never waits on a page past
// ``WebSwapGate/answerWithin``. A hidden or frozen page is never asked, so it never holds the swap:
// it keeps its document, which loads its lazy chunks from its own files (``WebBundleOverlay/Pin``),
// and reloads when it shows (p13-webui.md 3.C).
extension WebUpdates {
    /// The pages the page host shows now; none before the host exists.
    var shownPages: [any WebBundlePage] { pages()?.shownBundlePages ?? [] }

    /// Books the next look: at once while no page shows, after ``WebSwapGate/grace`` behind other
    /// apps, else when the input quiet period could end. Replaces a booked look.
    func scheduleSafePoint() {
        guard pending != nil else { return safePoint.cancel() }
        let wait: Duration = if shownPages.isEmpty {
            .zero
        } else if NSApp?.isActive ?? false {
            .milliseconds(Int(max(0, WebSwapGate.seconds(WebSwapGate.quietInput) - Self.idleSeconds()) * 1000))
        } else {
            WebSwapGate.grace
        }
        safePoint.schedule(after: wait) { @MainActor [weak self] in await self?.look() }
    }

    /// Swaps when the app and every shown page allow it, else books the next look. The shown pages
    /// are asked twice, all at once each time; the second pass and the checks after it run right
    /// before the swap, so a page that got busy (or started loading) after its first answer holds it.
    func look() async {
        guard pending != nil, !looking else { return }
        looking = true
        defer { looking = false }
        let generation = pendingGeneration
        var decision = appDecision()
        if decision == .askPages {
            let shown = shownPages
            let documents = shown.map(\.bundleDocument)
            decision = WebSwapGate.pages(await Self.askAll(shown))
            if decision == .swap { decision = WebSwapGate.pages(await Self.askAll(shown)) }
            // A page that came up, navigated or started loading while the pages answered was not
            // asked about what it shows now: it is asked next time.
            if decision == .swap,
               Set(shownPages.map { ObjectIdentifier($0) }) != Set(shown.map { ObjectIdentifier($0) })
               || shown.map(\.bundleDocument) != documents || shown.contains(where: \.bundleLoading) {
                decision = .later(after: .seconds(1), reason: "page.changed")
            }
            // Input, a sheet or a switch away that came while the pages answered still holds it.
            if decision == .swap {
                let again = appDecision()
                if case .later = again { decision = again }
            }
        }
        guard pending != nil else { return }
        // Another update was handed over while the pages answered: look again for that one.
        if generation != pendingGeneration { decision = .later(after: .zero, reason: "update.new") }
        switch decision {
        case .swap, .askPages:
            applyPending()
        case .later(let after, let reason):
            heldBy = reason
            safePoint.schedule(after: after) { @MainActor [weak self] in await self?.look() }
        }
    }

    private func appDecision() -> WebSwapGate.Decision {
        let pagesShown = !shownPages.isEmpty
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
