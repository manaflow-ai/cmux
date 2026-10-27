import AppKit
import WebKit

/// A WebKit page's UI delegate: its `<input type="file">` goes to ``PageOpenPanel`` when the host has
/// one (none: the input does nothing, as with no delegate), and WebKit's local Web Inspector says
/// here when it opens on the page and when it closes, docked or in its own window
/// (`WKUIDelegatePrivate`'s `_webView:didAttachLocalInspector:` and `_webView:willCloseLocalInspector:`),
/// which the page holds as its `inspector` keep reason. A web view holds its UI delegate weakly: the
/// ``PageWebView`` that sets it keeps it.
@MainActor
final class PageUIDelegate: NSObject, WKUIDelegate {
    /// The host's file chooser; nil when the host has no open panel (tests).
    let fileInputs: PageOpenPanel?
    /// Web Inspector opened (`true`) or closed (`false`) on the page: once per change.
    var onInspector: (@MainActor (Bool) -> Void)?
    /// Whether Web Inspector is open on the page now.
    private(set) var inspectorOpen = false

    init(fileInputs: PageOpenPanel?) {
        self.fileInputs = fileInputs
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        guard let fileInputs else { return completionHandler(nil) }
        fileInputs.webView(webView, runOpenPanelWith: parameters, initiatedByFrame: frame, completionHandler: completionHandler)
    }

    @objc(_webView:didAttachLocalInspector:)
    func webView(_ webView: WKWebView, didAttachLocalInspector inspector: NSObject) {
        inspectorChanged(true)
    }

    @objc(_webView:willCloseLocalInspector:)
    func webView(_ webView: WKWebView, willCloseLocalInspector inspector: NSObject) {
        inspectorChanged(false)
    }

    func inspectorChanged(_ open: Bool) {
        guard open != inspectorOpen else { return }
        inspectorOpen = open
        onInspector?(open)
    }
}
