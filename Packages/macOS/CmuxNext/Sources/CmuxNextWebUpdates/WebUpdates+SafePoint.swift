import AppKit
import CmuxNextPages
import CmuxNextUpdater
import CmuxNextWakeups
import CoreGraphics
import WebKit

// The safe point (plans/cmux-next/web-ota.md, ``WebSwapGate``). While an update is pending, one
// DemandTimer (`web-updates.safe-point`) books the next look; a look either swaps or books the
// next one. It stops when nothing is pending: a swap (here or `updates.web.apply`) cancels it, and
// a look that finds nothing pending books none. Each look asks every served page (twice), in the
// page's own world, through `window.cmuxWebSwap.hold()` (webviews/src/pages/shared/webSwap.ts),
// and never waits on a page past ``WebSwapGate/answerWithin``.
extension WebUpdates {
    /// Books the next look: at once while no page shows, after ``WebSwapGate/grace`` behind other
    /// apps, else when the input quiet period could end. Replaces a booked look.
    func scheduleSafePoint() {
        guard pending != nil else { return safePoint.cancel() }
        let wait: Duration = if WebBundleServedViews.shared.shown.isEmpty {
            .zero
        } else if NSApp.isActive {
            .milliseconds(Int(max(0, WebSwapGate.seconds(WebSwapGate.quietInput) - Self.idleSeconds()) * 1000))
        } else {
            WebSwapGate.grace
        }
        safePoint.schedule(after: wait) { @MainActor [weak self] in await self?.look() }
    }

    /// Swaps when the app and every page allow it, else books the next look. The pages are asked
    /// twice, all at once each time; the second pass and the checks after it run right before the
    /// swap, so a page that got busy (or started loading) after its first answer holds it.
    func look() async {
        guard pending != nil, !looking else { return }
        looking = true
        defer { looking = false }
        let generation = pendingGeneration
        var decision = appDecision()
        if decision == .askPages {
            let views = WebBundleServedViews.shared.shown
            let documents = views.map(\.url)
            decision = WebSwapGate.pages(await Self.askAll(views))
            if decision == .swap { decision = WebSwapGate.pages(await Self.askAll(views)) }
            // A page that came up, navigated or started loading while the pages answered was not
            // asked about what it shows now: it is asked next time.
            if decision == .swap,
               Set(WebBundleServedViews.shared.shown.map(ObjectIdentifier.init)) != Set(views.map(ObjectIdentifier.init))
               || views.map(\.url) != documents || views.contains(where: \.isLoading) {
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
        let away = resignedAt.map { WebSwapGate.seconds(.now - $0) } ?? .infinity
        return WebSwapGate.app(pagesShown: !WebBundleServedViews.shared.shown.isEmpty, active: NSApp.isActive,
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
    static func askAll(_ views: [WKWebView]) async -> [String?] {
        guard !views.isEmpty else { return [] }
        let script = """
        const swap = window.cmuxWebSwap;
        if (!swap || typeof swap.hold !== "function") return "page.no-hook";
        const held = await swap.hold();
        return typeof held === "string" && held ? held : null;
        """
        return await withCheckedContinuation { (done: CheckedContinuation<[String?], Never>) in
            let answers = Answers(count: views.count, done)
            let deadline = DemandTimer(owner: "web-updates.page-answer")
            answers.deadline = deadline
            deadline.schedule(after: WebSwapGate.answerWithin) { @MainActor in answers.finish() }
            for (index, view) in views.enumerated() {
                if view.isLoading {
                    answers.set(index, "page.loading")
                    continue
                }
                view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): answers.set(index, (value as? String).flatMap { $0.isEmpty ? nil : $0 })
                    case .failure: answers.set(index, "page.error")
                    }
                }
            }
        }
    }

    /// The pages' answers for one ask: resumes once, when every page answered or at the deadline
    /// (an unanswered page reads `page.no-answer`), and cancels the deadline then.
    @MainActor private final class Answers {
        private var values: [String??]
        private var left: Int
        private var done: CheckedContinuation<[String?], Never>?
        var deadline: DemandTimer?

        init(count: Int, _ done: CheckedContinuation<[String?], Never>) {
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
