public import AppKit
import CmuxNextSettings
import CmuxNextWakeups
import WebKit

/// App health's page half on the host (the shared health contract, part kind `page`): the page view
/// reports what it sees, and the App's feed turns it into the Rust health model's signals. This
/// module has no daemon and no health model, so it only calls the feed of the page host the view was
/// made with (``PageWebView/healthFeed``, ``PageChromiumHosting/healthFeed``).
@MainActor
public protocol PageHealthFeed: AnyObject {
    /// The page's heartbeat (`cmux.page.heartbeat`), with the key and pointer presses it handled.
    func pageBeat(_ page: PageWebView, handled: UInt64)
    /// A real key or mouse event reached the page's view (its first since the last beat matters).
    func pageInput(_ page: PageWebView)
    /// The page's view may have been shown or hidden; read ``PageWebView/isShownForHealth``.
    func pageVisibilityChanged(_ page: PageWebView)
    /// A document finished loading.
    func pageLoaded(_ page: PageWebView)
    /// A main-frame load failed (not a cancelled one).
    func pageLoadFailed(_ page: PageWebView)
    /// The page's web content process or renderer ended.
    func pageCrashed(_ page: PageWebView)
    /// The renderer of the page's Chromium tab stopped answering (true) or answers again (false).
    func pageRenderer(_ page: PageWebView, unresponsive: Bool)
    /// The tab closed: the page is gone for good.
    func pageClosed(_ page: PageWebView)
}

extension PageWebView {
    /// This view's health part (`page:<instance>`, the `debug.page` instance).
    public var healthPartID: String { "page:\(PageRegistry.instance(of: self))" }

    /// The page in plain words for the health indicator ("Agent chat" for `agent-chat`).
    public var healthLabel: String {
        let words = descriptor.resource.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Whether the person can see the page now: in a window that is on screen (not occluded, not in
    /// the Dock) and under no hidden ancestor. A page that cannot be seen stops its heartbeat (the
    /// document is hidden), so health never times it.
    public var isShownForHealth: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, !isParkedSpare else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// App health's `reloadPage`: the page saves its scroll and draft (`cmux.page.save_state`, waited
    /// for at most `saveWait`; a hung page cannot answer, and its last autosave is used), then the
    /// document reloads in whichever engine shows it. Never blocks: the wait is a suspension.
    /// False when it did not reload: the page closed, or holds unsaved edits once the save wait ends.
    @discardableResult
    public func reloadKeepingState(saveWait: Duration = .milliseconds(500)) async -> Bool {
        guard !isClosed else { return false }
        // A document that never loaded or whose process ended has nothing to save, and a WebKit
        // `reload()` of a view whose process ended does nothing: load it in a new process.
        guard loaded else {
            reloadAfterCrashes()
            return true
        }
        let done = PageHealthOnce()
        // task-owner: one save request; ends with the page's reply or its reset (the reload that follows).
        Task { [weak self] in
            _ = try? await self?.router.callPage(PageNativeOp.pageSaveState, params: .object([:]))
            done.finish()
        }
        let deadline = DemandTimer(owner: "page.health.saveState")
        // wakeup-allow: one bound on the save request, cancelled when the page answers first.
        deadline.schedule(after: saveWait) { @MainActor in done.finish() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in done.hold(continuation) }
        deadline.cancel()
        // An edit that came while the page saved (a hung page that answers again) is not reloaded away.
        guard !isClosed, !holdsEdits else { return false }
        reloadPage()
        return true
    }

    /// App health's `restartRenderer`: ends the page's renderer and brings the page back in a new
    /// one. Chromium: the tab's own unresponsive-renderer answer (terminate), then its reload.
    /// WebKit: its web content process ends (WebKit's `_killWebContentProcess`) and the crash path
    /// reloads it (``contentProcessTerminated()``); a WebKit without that call loads the document again.
    public func restartRenderer() {
        guard !isClosed else { return }
        guard loaded else { return reloadAfterCrashes() }
        rendererRestartPending = true
        if let chromiumPage {
            chromiumPage.restartRenderer()
            return
        }
        if !killWebContentProcess() {
            rendererRestartPending = false
            reloadAfterCrashes()
        }
    }

    /// Ends this page's WebContent process (WebKit's `_killWebContentProcess`); false when WebKit has no such call.
    func killWebContentProcess() -> Bool {
        let selector = NSSelectorFromString("_killWebContentProcess")
        guard webView.responds(to: selector) else { return false }
        webView.perform(selector)
        return true
    }

    /// Debug builds only: allows the page's fault injection (`window.__cmuxHealthInjectAllowed`, read by
    /// webviews/src/pages/shared/pageHealth.ts before page code runs), at the start of every document.
    func allowHealthInjection() {
        #if DEBUG
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: "window.__cmuxHealthInjectAllowed = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        #endif
    }

    /// Debug fault injection (`debug.health.inject`, Debug and tagged builds): the page's own
    /// `__cmuxHealthInject({fault: "hang"})`, which exists only when the host allowed it before page
    /// code ran (``allowHealthInjection()``). Returns whether the page has the function.
    public func injectHealthHang() async -> Bool {
        let script = "if (typeof window.__cmuxHealthInject !== 'function') { return false; } window.__cmuxHealthInject({fault: 'hang'}); return true;"
        return await callPageFunction(script) as? Bool == true
    }
}

/// Resumes a wait once, from whichever of its ends comes first (also one that came before the wait).
@MainActor
private final class PageHealthOnce {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func hold(_ continuation: CheckedContinuation<Void, Never>) {
        if finished { continuation.resume() } else { self.continuation = continuation }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
