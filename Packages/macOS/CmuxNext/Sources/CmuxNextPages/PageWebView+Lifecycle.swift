import ObjectiveC
public import WebKit

/// What the page lifecycle froze a page in (``PageWebView/freezePage()``).
enum PageFrozenEngine {
    /// The Chromium page with this identity, frozen through ``PageChromiumPage/setFrozen(_:)``.
    case chromium(ObjectIdentifier)
    /// The WebKit view, hidden in its window with WebKit's hidden-page throttling on.
    case webKit
}

@MainActor
extension PageWebView {
    // MARK: Freeze and thaw (p13-webui.md 3.C)

    /// Whether the page shows now: in a window, with no hidden view above it.
    var isShownInWindow: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// Freezes the hidden page for the page lifecycle: its timers, tasks and frames stop, its memory
    /// and state stay. Hidden comes first, then the freeze, as Chrome freezes only hidden pages
    /// (`WebContents::SetPageFrozen`, content/public/browser/web_contents.h). Chromium: the page is
    /// told it is hidden, then frozen once. WebKit stays in its window (no detach; p13-webui-029
    /// measures one): its view is hidden, which stops its frames and makes `document.hidden` true, and
    /// WebKit's own hidden-page throttling is turned on (``WKPreferences/enableHiddenPageThrottling()``).
    ///
    /// - Returns: True when the page is frozen (a second call makes no second engine call); false
    ///   when refused: the page shows, its Chromium page is still starting, or the engine did not
    ///   freeze it.
    @discardableResult
    func freezePage() -> Bool {
        if frozenEngine != nil { return true }
        guard !isShownInWindow else { return false }
        if engineDecision.engine == .webKit, chromiumSession == nil {
            webView.isHidden = true
            webView.configuration.preferences.enableHiddenPageThrottling()
            frozenEngine = .webKit
            return true
        }
        guard let page = chromiumSession?.page else { return false }
        page.setVisible(false)
        guard page.setFrozen(true) else { return false }
        frozenEngine = .chromium(ObjectIdentifier(page))
        return true
    }

    /// Thaws a frozen page, in the turn of its show and before it is visible (``setEngineVisible(_:)``
    /// thaws first too). Chromium: the page thaws, and is shown only after. WebKit: the view is
    /// shown in its window again; the throttling stays, as it acts only while the page is hidden.
    /// Does nothing on a running page.
    func thawPage() {
        guard let engine = frozenEngine else { return }
        frozenEngine = nil
        switch engine {
        case .chromium(let identity):
            // The Chromium page ended meanwhile (a fallback to WebKit): nothing of it is frozen.
            guard let page = chromiumSession?.page, ObjectIdentifier(page) == identity else { return }
            page.setFrozen(false)
        case .webKit:
            if chromiumSession == nil { webView.isHidden = false }
        }
    }

    /// The tab closed: cancels subscriptions and stops the bridge.
    public func close() {
        _ = claimState.end()
        router.close()
        bridge.uninstall()
        endChromium()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: PagePaintProbe.handlerName, contentWorld: .page)
        resumeLoadWaiters()
        traceOpenEnd(.closedBeforePaint)
    }

    /// Waits for the current document to finish loading or fail, and for a pending claim to be acknowledged (or its fallback reload to finish).
    public func waitUntilLoaded() async {
        guard !loaded || claimState.pending else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadWaiters.append(continuation)
        }
    }

    func resumeLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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
        contentProcessTerminated()
    }

    /// The page's web content process ended (either engine): reload unless it keeps crashing.
    func contentProcessTerminated() {
        loaded = false
        router.reset()
        let reloading = crashReloads.shouldReload(at: now())
        if reloading {
            reloadPage()
        } else {
            loadState.set(loading: false, page: self) // no load follows
            logger.error("page \(self.descriptor.id, privacy: .public) keeps crashing; not reloaded")
        }
        onCrash?(self, reloading)
    }

    /// Reloads a page that stopped reloading after crashes, and forgets those crashes (the crash notice's Reload button).
    public func reloadAfterCrashes() {
        crashReloads = PageCrashReloads()
        reloadPage()
    }
}

extension WKPreferences {
    /// WebKit's hidden-page throttling (`WKPreferencesPrivate.h`): the DOM timers of a hidden page are
    /// throttled, the throttle grows while it stays hidden, and the web process may be suppressed
    /// (App Nap) while it shows no page. Each acts only on a hidden page.
    static let hiddenPageThrottlingSetters = [
        "_setHiddenPageDOMTimerThrottlingEnabled:",
        "_setHiddenPageDOMTimerThrottlingAutoIncreases:",
        "_setPageVisibilityBasedProcessSuppressionEnabled:",
    ]

    /// Turns on every hidden-page throttling preference this WebKit has. WebKit sends the page a
    /// preferences update only for a value that changed, so a second call costs no update. A WebKit
    /// without one of them keeps its default.
    ///
    /// - Returns: How many of them this WebKit has.
    @MainActor @discardableResult
    func enableHiddenPageThrottling() -> Int {
        typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void
        var found = 0
        for name in Self.hiddenPageThrottlingSetters {
            // crash-allow: WebKit private selector, called only through the IMP class_getInstanceMethod found (no unknown-selector exception).
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(WKPreferences.self, selector) else { continue }
            unsafeBitCast(method_getImplementation(method), to: SetFlag.self)(self, selector, true)
            found += 1
        }
        return found
    }
}
