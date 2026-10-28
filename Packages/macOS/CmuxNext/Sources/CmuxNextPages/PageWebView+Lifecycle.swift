import CmuxNextDesign
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
public import WebKit

/// One caller of ``PageWebView/waitUntilLoaded()``: ``PageWebView/resumeLoadWaiters()`` resumes it once.
typealias PageLoadWaiter = OnceContinuation<Void, OnceContinuationError>

/// What the page lifecycle froze a page in (``PageWebView/freezePage()``).
enum PageFrozenEngine {
    /// The Chromium page with this identity, frozen through ``PageChromiumPage/setFrozen(_:)``.
    case chromium(ObjectIdentifier)
    /// The WebKit view, hidden in its window with all of WebKit's hidden-page throttling on; the
    /// thaw sets back `restoring`, the throttling it had before (nil: this WebKit could not read it).
    case webKit(restoring: WebKitHiddenPageThrottling?)
}

@MainActor
extension PageWebView {
    // MARK: Freeze and thaw (p13-webui.md 3.C)

    /// Whether the page shows now: in a window, with no hidden view above it, the AppKit state both
    /// engines take their visibility from (WebKit itself, ``setEngineVisible(_:)`` for Chromium).
    // visibility-walk-allow: the freeze guard must read the AppKit state the engines read (PageWebView has no VisibilityNode); one walk per freeze, at most once per pass
    var isShownInWindow: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// Freezes the hidden page for the page lifecycle: its timers, tasks and frames stop, its memory
    /// and state stay. Hidden comes first, then the freeze, as Chrome freezes only hidden pages
    /// (`WebContents::SetPageFrozen`, content/public/browser/web_contents.h): the page is not shown in
    /// its window, so AppKit's hide already reached the engine (``setEngineVisible(_:)`` from
    /// `viewDidHide` or `viewDidMoveToWindow`). Chromium: the page is frozen once. WebKit stays in its
    /// window (no detach; p13-webui-029 measures one): its view is hidden, which stops its frames,
    /// and all of WebKit's hidden-page throttling is on until the thaw. A frozen page's providers
    /// stop their sources (``PageRouter/pageWillFreeze()``).
    ///
    /// - Returns: True when the page is frozen (a second call makes no second engine call); false
    ///   when refused: the page shows, its Chromium page is still starting, or the engine did not
    ///   freeze it (it still counts the page visible). The lifecycle asks a refused page again later.
    @discardableResult
    func freezePage() -> Bool {
        if frozenEngine != nil { return true }
        guard !isShownInWindow else { return false }
        if engineDecision.engine == .webKit, chromiumSession == nil {
            let preferences = webView.configuration.preferences
            let restoring = preferences.hiddenPageThrottling
            webView.isHidden = true
            preferences.setHiddenPageThrottling(.full)
            frozenEngine = .webKit(restoring: restoring)
            router.pageWillFreeze()
            return true
        }
        guard let page = chromiumSession?.page, page.setFrozen(true) else { return false }
        frozenEngine = .chromium(ObjectIdentifier(page))
        router.pageWillFreeze()
        return true
    }

    /// Thaws a frozen page, in the turn of its show and before it is visible (``setEngineVisible(_:)``
    /// thaws first too). Chromium: the page thaws, and is shown only after. WebKit: the view is
    /// shown in its window again with the hidden-page throttling it had before the freeze, so a page
    /// the lifecycle keeps running while hidden is throttled no more than WebKit's own default.
    /// Then the pushes held while it was frozen run (``PageNativePushes/thawed()``) and the providers
    /// hear the thaw (``PageRouter/pageDidThaw()``). Does nothing on a running page.
    func thawPage() {
        guard let engine = frozenEngine else { return }
        frozenEngine = nil
        // The engine runs again first; then the providers restart their sources and resync, before
        // the router releases what it held.
        defer { router.pageDidThaw() }
        switch engine {
        case .chromium(let identity):
            if let page = chromiumSession?.page, ObjectIdentifier(page) == identity { page.setFrozen(false) }
        case .webKit(let restoring):
            if let restoring { webView.configuration.preferences.setHiddenPageThrottling(restoring) }
            if chromiumSession == nil { webView.isHidden = false }
        }
        pushes.thawed()
    }

    /// The frozen Chromium page ended and the page reopens in WebKit (``fallBackToWebKit(_:detail:)``):
    /// the WebKit page takes its place in the frozen state, so the lifecycle's `.frozen` stays true
    /// and its next pass (the reload's load reason) thaws it the usual way. A page that shows runs,
    /// and so do its providers.
    func carryFreezeToWebKit() {
        guard case .chromium? = frozenEngine else { return }
        frozenEngine = nil
        if !freezePage() { router.pageDidThaw() }
    }

    /// The tab closed: cancels subscriptions, stops the bridge and ends the engine page.
    public func close() {
        closeRoutes()
        closeEngine()
    }

    /// The first half of ``close()``, which ``WebUIHost/close(_:)`` runs in the close's turn: the routes,
    /// subscriptions, pending calls and bridge end, so nothing serves a page no tab shows. It asks the
    /// engine page nothing.
    func closeRoutes() {
        _ = claimState.end()
        firstShowStart = nil // a page closed before it showed never starts
        firstShowWatch = nil
        router.end()
        webKitPieces?.bridge.uninstall()
        userContent.removeScriptMessageHandler(forName: PagePaintProbe.handlerName, contentWorld: .page)
        resumeLoadWaiters()
        traceOpenEnd(.closedBeforePaint)
    }

    /// The second half of ``close()``: the Chromium page ends, and the WebKit view, if one was built, is retired
    /// (``WebViewRetirement``: stopped, its page closed only after its scrolling ended, so macOS 26.6's WebKit never
    /// leaves a freed display-link client registered, cmux#25322). ``WebUIHost/close(_:)`` runs it at its retirer's
    /// deadline.
    func closeEngine() {
        endChromium()
        chromiumRecovery = nil
        if let view = webKitPieces?.view {
            view.stopLoading()
            WebViewRetirement.retire(view)
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        censusState.engineClosed?()
        #endif
    }

    /// Waits for the current document to finish loading or fail, and for a pending claim to be acknowledged (or its fallback reload to finish).
    public func waitUntilLoaded() async {
        guard !loaded || claimState.pending else { return }
        try? await withOnceContinuation { (continuation: PageLoadWaiter) in
            loadWaiters.append(continuation)
        }
    }

    func resumeLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ()) }
    }

    // crash-allow: WebKit delegate signature uses nullable navigation handles.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        loadState.set(loading: false, page: self)
        resumeLoadWaiters()
    }

    // crash-allow: WebKit delegate signature uses nullable navigation handles.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        loadState.set(loading: false, page: self)
        resumeLoadWaiters()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crash.webKitContentEnded()
        contentProcessTerminated()
    }

    /// The page's web content process ended (either engine): ``PageCrashRecovery`` reloads it now, when it shows, or not
    /// at all once it keeps crashing. A host that shows the crash notice instead (``reloadsAfterCrash`` false) gets every
    /// crash and no reload. A closed page waiting for its engine close (``WebUIHost/close(_:)``) never reloads.
    func contentProcessTerminated() {
        guard !router.isEnded else { return }
        guard reloadsAfterCrash else {
            loaded = false
            router.reset()
            loadState.set(loading: false, page: self) // no load follows now
            // A renderer that crashed before the page reached the host leaves the Chromium start
            // deadline armed: its fallback would load the page in WebKit by itself.
            chromiumSession?.deadline.cancel()
            logger.error("page \(self.descriptor.id, privacy: .public) web content ended; no automatic reload (the crash notice offers Reload)")
            onCrash?(self, false)
            return
        }
        crash.crashed(self)
    }

    /// Reloads a page that stopped reloading after crashes, and forgets those crashes (the crash notice's Reload button).
    public func reloadAfterCrashes() {
        guard webKitLoadsOnReload else { return crash.reloadAfterCrashes(self) }
        // Chromium ended while the notice showed: the page reopens in WebKit now.
        webKitLoadsOnReload = false
        loadDocument(descriptor.url(route: route))
    }
}
