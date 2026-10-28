import AppKit

/// The parent view of this pane's Chromium window: the `parent_view` argument of `create_window`,
/// `create_placeholder_window` and `popup_window_attach` (task 023 of
/// plans/cmux-next/chrome-parity/p01-process.md).
///
/// In process the fork's page window follows ``CEFHostView``: its tracker reads the view's place,
/// clip and occlusion rects. In host mode Chromium's window lives in the Chromium Host, so the
/// parent is the pane's ``ChromiumHostPageView``, named by the token cmux minted for it: no view
/// pointer reaches the remote shim, which sends the token as is (remote_shim_runtime.h,
/// `TlvWriter::View`), and the host keeps a view of its own behind it (host_dispatch.h,
/// `PageViews`). The page view shows the Core Animation context id the host gives for that window
/// (``showHostedContext(of:)``). Chrome splits a page the same way: the browser process owns the
/// widget and its compositor, and the app shim's `RenderWidgetHostNSView` only hosts its layers
/// (content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm).
extension CEFPaneHost {
    /// The Chromium Host runs this pane's Chromium (``BrowserBackend/host``).
    var isHostMode: Bool { runtime.hostStart != nil }

    /// What the shim's `parent_view` arguments name for this pane: the page view's token in host
    /// mode; in process ``hostView``, unretained, which the pane host keeps while its window uses it.
    func pageParent() -> CEFParentView {
        guard isHostMode else { return CEFParentView(view: hostView) }
        return CEFParentView(token: hostedPage().wireToken)
    }

    /// Host mode: the pane's page view, made on first use at the bottom of ``hostView`` and filling
    /// it, under the find bar, prompt bar and every other subview. With the host's input route
    /// (feature `chromiumHostInputRing`, ``CEFHostStart/inputRoute``) it is the page's input
    /// target: its keys, clicks, moves and wheel ticks go into the host's ring for the pane's shown
    /// tab, paced by the host's acks. Without it its input stays with ``hostView``
    /// (``ChromiumHostPageView/InputTarget/pageWindow``). Its input method ops go to the host
    /// either way (``sendTextInput(_:)``).
    func hostedPage() -> ChromiumHostPageView {
        if let hostedPageView { return hostedPageView }
        #if DEBUG || CMUX_BENCH_HOOKS
        let route = runtime.hostStart?.inputRoute
        let target: ChromiumHostPageView.InputTarget = route == nil ? .pageWindow : .view
        #else
        let target = ChromiumHostPageView.InputTarget.pageWindow
        #endif
        let page = ChromiumHostPageView(frame: hostView.bounds, inputTarget: target)
        page.wireToken = runtime.mintPageViewToken()
        // The page's focus follows the view's first responder state (``CEFTab/applyFocus(_:browser:)``).
        page.onFocusChange = { [weak self] focused in self?.visibleTab?.hostedPageFocusChanged(focused) }
        // What the person sees of the page goes to the host (``postPageVisibility(browser:)``).
        page.onPageVisibility = { [weak self] _ in
            self?.postPageVisibility()
            self?.hostPageShownChanged()  // the busy deadline runs only while a hosted page shows
        }
        // The page's display follows the view's (task 221): the host places the page window there.
        // With no tab shown yet nothing goes out; ``showBrowser(of:activate:)`` places it then.
        page.onScreenInfo = { [weak self, weak page] _ in
            guard let self, let page, let browser = visibleTab?.browserID else { return false }
            return runtime.placeHostedPage(page, browser: browser)
        }
        // The page's accessibility element comes from the host (CEFPaneHost+Accessibility.swift).
        page.accessibilityTokenSource = { [weak self] request, answered in
            guard let self else { return answered(nil) }
            askPageAccessibility(request, answered: answered)
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        page.textInputSink = { [weak self] op in self?.sendTextInput(op) }
        page.wordLookUp = { [weak self] point, scale, answered in
            guard let self else { return answered(nil) }
            lookUpWord(at: point, scale: scale, answered: answered)
        }
        // No macOS caret accessory while the shown tab is a cmux page, as on Chromium's own view of one.
        page.showsCmuxPage = { [weak self] in self?.visibleTab?.pageThemeSurface != nil }
        // Two-finger Back and Forward swipes over the shown page, from the host's wheel acks (task 234).
        page.wheelGesture = { [weak self, weak page] event in
            guard let self, let page, let tab = visibleTab else { return false }
            return runtime.swipeNavigation.handleHosted(event, tab: tab, page: page)
        }
        // The page's keys, clicks, moves and wheel ticks into the host's ring for the shown tab (task 042).
        route?.attach(page) { [weak self] in self?.visibleTab?.browserID }
        #endif
        // The host's page window takes the view's size in the same commit as the pane (task 052).
        page.onGeometry = { [weak self, weak page] geometry in
            guard let self, let page else { return }
            runtime.hostPageResizes()?.resize(view: page.wireToken, browser: visibleTab?.browserID ?? 0, geometry: geometry,
                                              in: page.window)
        }
        hostView.addSubview(page, positioned: .below, relativeTo: nil)
        hostView.showOcclusion(in: page)
        hostedPageView = page
        takeHostDrags(on: page)
        runtime.hostStart?.locks?.serve(page)
        return page
    }

    /// Host mode: shows `browser`'s page window in ``hostedPageView``. The host turns on the fork's
    /// layer hosting (API 26) of the page window it keeps behind the page view's token, and its REPLY
    /// carries the window's Core Animation context id. A reply for a window this pane no longer
    /// has shows nothing. The page window is placed on the page view's display (task 221).
    func showHostedContext(of browser: Int32) {
        guard let page = hostedPageView, runtime.forkAPIVersion >= CEFLayerHosting.forkAPI else { return }
        let shown = window
        // A page window the host opened since the last size went (a new host, a new browser on this
        // view's token) takes the view's size before it shows: sent again even when it did not change.
        if let pageWindow = page.window, page.bounds.width >= 1, page.bounds.height >= 1 {
            let geometry = ChromiumHostGeometry(screenRect: pageWindow.convertToScreen(page.convert(page.bounds, to: nil)),
                                                scale: pageWindow.backingScaleFactor)
            runtime.hostPageResizes()?.resize(view: page.wireToken, browser: browser, geometry: geometry, in: pageWindow,
                                              resend: true)
        }
        // Before the hosting op: the host applies it when it detaches the page window.
        postPageVisibility(browser: browser)
        let sent = runtime.sendAsync { $0.browserSetLayerHosting(browser, 1) }
        // After the hosting op on the same ordered channel: the detached window takes the view's display.
        runtime.placeHostedPage(page, browser: browser)
        runtime.whenAnswered(sent, label: "page context") { [weak self, weak page] id in
            guard let self else { return }
            // A context means the host detached the page window (it refuses hosting it cannot
            // detach): the page's focus is embedder-active from here.
            if let id, id != 0 { runtime.tabsByBrowser[browser]?.hostDetachedPage(browser: browser) }
            guard let page, hostedPageView === page, window == shown else { return }
            if let id, id != 0, page.show(contextID: id) { return }
            runtime.logger.error("Chromium Host gave no page context for browser \(browser)")
        }
    }

    /// Host mode: tells the host what the person sees of this pane's page
    /// (``ChromiumHostPageView/pageVisibility``), as Chrome's page view tells its WebContents. The
    /// fork shows, hides or occludes the Chromium window of `browser` (by default a browser of this
    /// pane's window), every tab of it.
    func postPageVisibility(browser: Int32? = nil) {
        guard let page = hostedPageView, let browser = browser ?? anchorBrowser else { return }
        _ = runtime.shim?.browserSetPageVisibility(browser, page.pageVisibility.rawValue)
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
extension CEFPaneHost {
    /// Host mode: sends the page view's input method op to the host's IME exports for the shown
    /// tab's browser, on the control channel after the keys written before it, as
    /// Chrome's page view calls its RenderWidgetHostNSViewHost (render_widget_host_ns_view.mojom).
    /// Nothing goes with no browser shown, or when the host's shim lacks an IME op
    /// (``CEFShimTextInputOps/isComplete``), as no widget shows without every widget op
    /// (``CEFRuntime/showHostWidgets(_:)``). The shim is read per op, so a restarted host's counts.
    func sendTextInput(_ op: ChromiumHostTextInputOp) {
        guard let browser = visibleTab?.browserID, let ime = runtime.shim?.textInput, ime.isComplete else { return }
        ime.send(op, browser: browser)
    }
}
#endif

extension CEFRuntime {
    /// A new page view token (``ChromiumHostPageView/wireToken``): never 0, never reused.
    func mintPageViewToken() -> UInt64 {
        lastPageViewToken += 1
        return lastPageViewToken
    }
}
