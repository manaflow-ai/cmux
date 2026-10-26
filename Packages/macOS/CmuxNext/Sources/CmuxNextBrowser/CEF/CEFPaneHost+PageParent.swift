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
    func pageParent() -> UnsafeMutableRawPointer? {
        guard isHostMode else { return Unmanaged.passUnretained(hostView).toOpaque() }
        return UnsafeMutableRawPointer(bitPattern: UInt(hostedPage().wireToken))
    }

    /// Host mode: the pane's page view, made on first use at the bottom of ``hostView`` and filling
    /// it, under the find bar, prompt bar and every other subview. Its input stays with
    /// ``hostView`` (``ChromiumHostPageView/InputTarget/pageWindow``) until the input route to the
    /// host lands (tasks 041 and 042). Its input method ops already go to the host
    /// (``sendTextInput(_:)``).
    func hostedPage() -> ChromiumHostPageView {
        if let hostedPageView { return hostedPageView }
        let page = ChromiumHostPageView(frame: hostView.bounds, inputTarget: .pageWindow)
        page.wireToken = runtime.mintPageViewToken()
        // The page's focus follows the view's first responder state (``CEFTab/applyFocus(_:browser:)``).
        page.onFocusChange = { [weak self] focused in self?.visibleTab?.hostedPageFocusChanged(focused) }
        #if DEBUG || CMUX_BENCH_HOOKS
        page.textInputSink = { [weak self] op in self?.sendTextInput(op) }
        #endif
        hostView.addSubview(page, positioned: .below, relativeTo: nil)
        hostView.showOcclusion(in: page)
        hostedPageView = page
        return page
    }

    /// Host mode: shows `browser`'s page window in ``hostedPageView``. The host turns on the fork's
    /// layer hosting (API 26) of the page window it keeps behind the page view's token, and its REPLY
    /// carries the window's Core Animation context id. A reply for a window this pane no longer
    /// has shows nothing.
    func showHostedContext(of browser: Int32) {
        guard let page = hostedPageView, runtime.forkAPIVersion >= CEFLayerHosting.forkAPI else { return }
        let shown = window
        let sent = runtime.sendAsync { $0.browserSetLayerHosting(browser, 1) }
        runtime.whenAnswered(sent, label: "page context") { [weak self, weak page] id in
            guard let self, let page, hostedPageView === page, window == shown else { return }
            if let id, id != 0, page.show(contextID: id) { return }
            runtime.logger.error("Chromium Host gave no page context for browser \(browser)")
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
extension CEFPaneHost {
    /// Host mode: sends the page view's input method op to the host's IME exports for the shown
    /// tab's browser, on the control channel after the keys written before it (p04-input-064), as
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
