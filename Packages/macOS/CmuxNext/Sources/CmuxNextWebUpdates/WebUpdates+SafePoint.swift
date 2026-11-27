import AppKit
import CmuxNextPages
import CmuxNextUpdater
import CmuxNextWakeups
import CoreGraphics
import WebKit

// The safe point (plans/cmux-next/web-ota.md, ``WebSwapGate``). While an open page still reads an
// older update than the pending one, one DemandTimer (`web-updates.safe-point`) books the next
// look; a look reloads every such page that is ready and books the next one for the rest. It stops
// once every open page reads the pending update: a look that leaves none behind, or
// `updates.web.apply`, cancels it. Each look asks the pages it may reload (twice), in the page's
// own world, through `window.cmuxWebSwap.hold()` (webviews/src/pages/shared/webSwap.ts), and never
// waits on a page past ``WebSwapGate/answerWithin``.
extension WebUpdates {
    /// Books the next look at once (``look()`` books its own waits). Replaces a booked look.
    func scheduleSafePoint() {
        guard pending != nil else { return safePoint.cancel() }
        safePoint.schedule(after: .zero) { @MainActor [weak self] in await self?.look() }
    }

    /// Reloads each open page that is behind the pending update and may reload now, and books the
    /// next look for the others. The pages are asked twice, all at once each time; the second pass
    /// and the checks after it run right before the reload, so a page that got busy (or started
    /// loading) after its first answer holds itself, and only itself.
    func look() async {
        guard let target = pending, !looking else { return }
        looking = true
        defer { looking = false }
        let generation = pendingGeneration
        let behind = WebBundleServedViews.shared.behind(target)
        guard !behind.isEmpty else { return finishPending() }
        if case .later(let after, let reason) = appDecision() { return book(after, reason) }
        let waited = pendingSince.map { WebSwapGate.seconds(.now - $0) } ?? 0
        let focused = Self.focusedWebView()
        var candidates: [WKWebView] = []
        var next: (after: Duration, reason: String)?
        for view in behind {
            switch WebSwapGate.input(focused: view === focused, active: NSApp.isActive, idle: Self.idleSeconds(), waited: waited) {
            case .later(let after, let reason): next = Self.sooner(next, (after, reason))
            case .askPages: candidates.append(view)
            }
        }
        let documents = Dictionary(uniqueKeysWithValues: candidates.map { (ObjectIdentifier($0), $0.url) })
        var (ready, held) = Self.ready(candidates, await Self.askAll(candidates))
        if !ready.isEmpty {
            let again = Self.ready(ready, await Self.askAll(ready))
            ready = again.views
            held = held ?? again.held
        }
        // A page that navigated or started loading while it answered was not asked about what it
        // shows now: it is asked next time.
        ready = ready.filter { view in !view.isLoading && documents[ObjectIdentifier(view)] == .some(view.url) }
        // Input on the page being typed into, a sheet or a switch away that came while the pages
        // answered still holds it.
        if case .later(let after, let reason) = appDecision() { return book(after, reason) }
        ready = ready.filter { view in
            if case .later = WebSwapGate.input(focused: view === Self.focusedWebView(), active: NSApp.isActive,
                                               idle: Self.idleSeconds(), waited: waited) { return false }
            return true
        }
        guard pending != nil else { return }
        // Another update was handed over while the pages answered: look again for that one.
        guard generation == pendingGeneration else { return book(.zero, "update.new") }
        WebBundleServedViews.shared.reload(ready, to: target)
        guard !WebBundleServedViews.shared.behind(target).isEmpty else { return finishPending() }
        if let held { next = Self.sooner(next, (WebSwapGate.retry, held)) }
        let wait = next ?? (.seconds(1), "page.changed")
        book(wait.after, wait.reason)
    }

    /// Books the next look after `after`; `reason` held the last one (`updates.web.status`).
    private func book(_ after: Duration, _ reason: String) {
        heldBy = reason
        safePoint.schedule(after: after) { @MainActor [weak self] in await self?.look() }
    }

    private static func sooner(_ a: (after: Duration, reason: String)?, _ b: (after: Duration, reason: String)) -> (after: Duration, reason: String) {
        guard let a else { return b }
        return a.after <= b.after ? a : b
    }

    /// The views of `views` whose answer (in `answers`, in order) lets them reload, and what held
    /// the first one that holds.
    private static func ready(_ views: [WKWebView], _ answers: [String?]) -> (views: [WKWebView], held: String?) {
        let (reload, held) = WebSwapGate.pages(answers)
        return (reload.map { views[$0] }, held)
    }

    private func appDecision() -> WebSwapGate.Decision {
        let away = resignedAt.map { WebSwapGate.seconds(.now - $0) } ?? .infinity
        return WebSwapGate.app(active: NSApp.isActive, blocked: Self.appBlocked(), away: away)
    }

    /// The served web view that has the keyboard: the first responder of cmux's key window, or the
    /// web view it sits in.
    static func focusedWebView() -> WKWebView? {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let current = view {
            if let webView = current as? WKWebView { return webView }
            view = current.superview
        }
        return nil
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
