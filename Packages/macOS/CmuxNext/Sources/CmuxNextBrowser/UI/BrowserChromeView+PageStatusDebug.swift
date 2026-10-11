#if DEBUG
import AppKit

extension BrowserChromeView {
    /// `debug.browser.page_status`: what the pane shows over the page.
    /// `error` is the cmux error page's title and message ("" while hidden),
    /// `certificate` "1" when it is the certificate warning, `gone` "1"
    /// while the sad tab shows.
    public var debugPageStatus: [String: String] {
        let status = pageStatus
        return [
            "error": status.errorView.isHidden ? "" : status.errorView.debugText,
            "certificate": !status.errorView.isHidden && status.errorView.isCertificateInterstitial ? "1" : "0",
            "gone": status.goneView.isHidden ? "0" : "1",
        ]
    }
}
#endif
