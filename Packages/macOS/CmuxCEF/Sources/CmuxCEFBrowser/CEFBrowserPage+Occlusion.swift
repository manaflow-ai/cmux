public import CmuxBrowser
public import CoreGraphics

extension CEFBrowserPage: BrowserPageOcclusionHosting {
    /// Native UI over the page, in ``contentView`` coordinates. The Chromium
    /// window leaves holes there (`CEFHostView.occlusionRects`).
    public var pageOcclusionRects: [CGRect] {
        get { browser.hostView.occlusionRects }
        set {
            guard browser.hostView.occlusionRects != newValue else { return }
            browser.hostView.occlusionRects = newValue
        }
    }
}
