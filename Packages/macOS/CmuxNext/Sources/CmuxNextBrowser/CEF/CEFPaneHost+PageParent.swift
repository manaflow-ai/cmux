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
    /// it, under the find bar, prompt bar and every other subview. Its input stays with
    /// ``hostView`` (``ChromiumHostPageView/InputTarget/pageWindow``) until the input route to the
    /// host lands (tasks 041 and 042).
    func hostedPage() -> ChromiumHostPageView {
        if let hostedPageView { return hostedPageView }
        let page = ChromiumHostPageView(frame: hostView.bounds, inputTarget: .pageWindow)
        page.wireToken = runtime.mintPageViewToken()
        // The page's focus follows the view's first responder state (``CEFTab/applyFocus(_:browser:)``).
        page.onFocusChange = { [weak self] focused in self?.visibleTab?.hostedPageFocusChanged(focused) }
        // The page's accessibility element comes from the host (CEFPaneHost+Accessibility.swift).
        page.accessibilityTokenSource = { [weak self] request, answered in
            guard let self else { return answered(nil) }
            askPageAccessibility(request, answered: answered)
        }
        hostView.addSubview(page, positioned: .below, relativeTo: nil)
        hostView.showOcclusion(in: page)
        hostedPageView = page
        takeHostDrags(on: page)
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

extension CEFRuntime {
    /// A new page view token (``ChromiumHostPageView/wireToken``): never 0, never reused.
    func mintPageViewToken() -> UInt64 {
        lastPageViewToken += 1
        return lastPageViewToken
    }
}
