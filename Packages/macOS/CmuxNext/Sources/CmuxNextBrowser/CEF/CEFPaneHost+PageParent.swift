import AppKit

/// The parent view of this pane's Chromium window: the NSView* argument of `create_window`,
/// `create_placeholder_window` and `popup_window_attach` (task 023 of
/// plans/cmux-next/chrome-parity/p01-process.md).
///
/// In process the fork's page window follows ``CEFHostView``: its tracker reads the view's place,
/// clip and occlusion rects. In host mode Chromium's window lives in the Chromium Host, so the
/// parent is the pane's ``ChromiumHostPageView``: the remote shim sends it as the view's token
/// (remote_shim_runtime.h, `TlvWriter::View`), the host keeps a view of its own behind that token
/// (host_dispatch.h, `PageViews`), and the page view shows the Core Animation context id the host
/// gives for it. Chrome splits a page the same way: the browser process owns the widget and its
/// compositor, and the app shim's `RenderWidgetHostNSView` only hosts its layers
/// (content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm).
extension CEFPaneHost {
    /// The Chromium Host runs this pane's Chromium (``BrowserBackend/host``).
    var isHostMode: Bool { runtime.hostStart != nil }

    /// The parent view the shim's NSView* arguments name for this pane, unretained: the pane host
    /// keeps the view (``hostView``, ``hostedPageView``) for as long as its window uses it.
    func pageParent() -> UnsafeMutableRawPointer {
        let view: NSView = isHostMode ? hostedPage() : hostView
        return Unmanaged.passUnretained(view).toOpaque()
    }

    /// Host mode: the pane's page view, made on first use at the bottom of ``hostView`` and filling
    /// it, under the find bar, prompt bar and every other subview. It is the page's input target
    /// (``ChromiumHostPageView/InputTarget/view``): no page window of the host takes cmux's input.
    func hostedPage() -> ChromiumHostPageView {
        if let hostedPageView { return hostedPageView }
        let page = ChromiumHostPageView(frame: hostView.bounds, inputTarget: .view)
        hostView.addSubview(page, positioned: .below, relativeTo: nil)
        hostedPageView = page
        return page
    }
}
