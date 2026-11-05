public import AppKit

/// A tab content view that holds more than the page (docked DevTools).
protocol BrowserPageViewportProviding: NSView {
    /// The page's own frame in this view's coordinates.
    var pageViewportFrame: CGRect { get }
    /// Where the page shows, in this view's coordinates (a fit's presented rect inside its frame).
    var presentedPageFrame: CGRect { get }
    /// Points per CSS px of the page's layout at zoom 1 (a fit's or a big device's scale; 1 otherwise).
    var presentedPageScale: CGFloat { get }
}

extension BrowserChromeView {
    /// The page's viewport in this view's coordinates: the page area minus
    /// a docked DevTools (CEF) or attached Web Inspector (WebKit). The
    /// agent cursor maps viewport CSS px into it.
    public var pageViewportRect: CGRect {
        let content = tab.contentView
        let page = (content as? any BrowserPageViewportProviding)?.presentedPageFrame ?? content.bounds
        return convert(page, from: content)
    }

    /// Points per CSS px of the page at zoom 1 in `pageViewportRect` (an emulation's scale, else 1):
    /// the agent cursor maps viewport CSS px with page zoom times this.
    public var pageViewportScale: CGFloat {
        (tab.contentView as? any BrowserPageViewportProviding)?.presentedPageScale ?? 1
    }

    /// Everything under the toolbar that can show the page's pixels: the page, a docked
    /// DevTools or Web Inspector, a sleeping page's picture and the page's overlays. An
    /// agent's window capture masks the whole chrome, this view included (`ScreenshotMask`).
    public var pageArea: NSView { contentContainer }

    /// Whether `view` is a browser tab's page content (a WebKit or Chromium page, with its
    /// docked tools), wherever it sits: a capture masks one even outside a chrome view.
    public static func isPageContent(_ view: NSView) -> Bool {
        view is WebKitPageContainer || view is CEFTabContentView
    }
}

extension WebKitPageContainer: BrowserPageViewportProviding {
    var pageViewportFrame: CGRect { page?.frame ?? bounds }
    /// The web view's frame in the (scaled) bounds; `convert` turns it into real points.
    var presentedPageFrame: CGRect { pageViewportFrame }
    var presentedPageScale: CGFloat { bounds.width > 0 ? frame.width / bounds.width : 1 }
}

extension CEFTabContentView: BrowserPageViewportProviding {
    var pageViewportFrame: CGRect {
        let page = tab?.devToolsController.frames(in: bounds).page ?? bounds
        return tab?.sidePanel.state?.contentsFrame(inPage: page) ?? page
    }
    /// A fit's presented rect (as `layoutContent` places the host), else the page frame.
    var presentedPageFrame: CGRect {
        guard tab?.sidePanel.state == nil, tab?.devToolsController.deviceModeOn != true, let rect = tab?.deviceEmulation?.presentedRect(in: pageViewportFrame) else { return pageViewportFrame }
        return rect
    }
    var presentedPageScale: CGFloat { tab?.devToolsController.deviceModeOn == true ? 1 : tab?.deviceEmulationViewport?.scale ?? 1 }
}
