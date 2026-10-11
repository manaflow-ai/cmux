public import AppKit

/// A tab content view that holds more than the page (docked DevTools).
protocol BrowserPageViewportProviding: NSView {
    /// The page's own frame in this view's coordinates.
    var pageViewportFrame: CGRect { get }
}

extension BrowserChromeView {
    /// The page's viewport in this view's coordinates: the page area minus
    /// a docked DevTools (CEF) or attached Web Inspector (WebKit). The
    /// agent cursor maps viewport CSS px into it.
    public var pageViewportRect: CGRect {
        let content = tab.contentView
        let page = (content as? any BrowserPageViewportProviding)?.pageViewportFrame ?? content.bounds
        return convert(page, from: content)
    }
}

extension WebKitPageContainer: BrowserPageViewportProviding {
    var pageViewportFrame: CGRect { page?.frame ?? bounds }
}

extension CEFTabContentView: BrowserPageViewportProviding {
    var pageViewportFrame: CGRect {
        let page = tab?.devToolsController.frames(in: bounds).page ?? bounds
        return tab?.sidePanel.state?.contentsFrame(inPage: page) ?? page
    }
}
