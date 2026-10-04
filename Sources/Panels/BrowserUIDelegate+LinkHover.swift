import AppKit
import CmuxBrowser
import WebKit

extension BrowserUIDelegate {
    /// WebKit reports the element under the pointer here, as Safari's status
    /// bar uses it. The link is `nil` once the pointer leaves a link.
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    @MainActor
    func webView(
        _ webView: WKWebView,
        mouseDidMoveOverElement hitTestResult: NSObject,
        withFlags flags: UInt,
        userInfo: Any?
    ) {
        let hover = BrowserLinkHoverURL.isEnabled() ? BrowserLinkHoverURL(hitTestResult: hitTestResult) : nil
        WindowBrowserSlotView.hosting(webView)?.setLinkHoverURL(hover?.displayString)
    }
}
