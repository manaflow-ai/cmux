import AppKit
import CmuxNextPages
import CmuxNextUpdater
import CmuxNextWakeups
import CoreGraphics
import WebKit

// The safe point (plans/cmux-next/web-ota.md, ``WebSwapGate``). While an update is pending, one
// DemandTimer (`web-updates.safe-point`) books the next look; a look either swaps or books the
// next one. It stops when nothing is pending: a swap (here or `updates.web.apply`) cancels it, and
// a look that finds nothing pending books none. Each look asks every served page once, in the
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

    /// Swaps when the app and every page allow it, else books the next look.
    func look() async {
        guard pending != nil, !looking else { return }
        looking = true
        defer { looking = false }
        var decision = appDecision()
        if decision == .askPages {
            let views = WebBundleServedViews.shared.shown
            var answers: [String?] = []
            for view in views { answers.append(await Self.ask(view)) }
            decision = WebSwapGate.pages(answers)
            // Input or a sheet that came while the pages answered still holds it.
            if decision == .swap {
                let again = appDecision()
                if case .later = again { decision = again }
            }
        }
        guard pending != nil else { return }
        switch decision {
        case .swap, .askPages:
            applyPending()
        case .later(let after, let reason):
            heldBy = reason
            safePoint.schedule(after: after) { @MainActor [weak self] in await self?.look() }
        }
    }

    private func appDecision() -> WebSwapGate.Decision {
        WebSwapGate.app(pagesShown: !WebBundleServedViews.shared.shown.isEmpty, active: NSApp.isActive,
                        idle: Self.idleSeconds(), blocked: Self.appBlocked())
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

    /// The page's answer: nil when a reload keeps all it holds, else why not. A page still
    /// loading, without the hook, failing or silent past ``WebSwapGate/answerWithin`` is busy.
    static func ask(_ webView: WKWebView) async -> String? {
        if webView.isLoading { return "page.loading" }
        let script = """
        const swap = window.cmuxWebSwap;
        if (!swap || typeof swap.hold !== "function") return "page.no-hook";
        const held = await swap.hold();
        return typeof held === "string" && held ? held : null;
        """
        return await withCheckedContinuation { (answer: CheckedContinuation<String?, Never>) in
            let once = Once(answer)
            let deadline = DemandTimer(owner: "web-updates.page-answer")
            once.deadline = deadline
            deadline.schedule(after: WebSwapGate.answerWithin) { @MainActor in once.resume("page.no-answer") }
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): once.resume((value as? String).flatMap { $0.isEmpty ? nil : $0 })
                case .failure: once.resume("page.error")
                }
            }
        }
    }

    /// Resumes a page's answer once: the first of its reply and its deadline.
    @MainActor private final class Once {
        private var answer: CheckedContinuation<String?, Never>?
        var deadline: DemandTimer?

        init(_ answer: CheckedContinuation<String?, Never>) {
            self.answer = answer
        }

        func resume(_ value: String?) {
            deadline?.cancel()
            deadline = nil
            answer?.resume(returning: value)
            answer = nil
        }
    }
}
