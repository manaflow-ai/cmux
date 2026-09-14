import Foundation

/// Weak association between an AppKit field editor and its browser owner.
final class CmuxFieldEditorOwningWebViewBox: NSObject {
    weak var webView: CmuxWebView?

    init(webView: CmuxWebView?) {
        self.webView = webView
    }
}
