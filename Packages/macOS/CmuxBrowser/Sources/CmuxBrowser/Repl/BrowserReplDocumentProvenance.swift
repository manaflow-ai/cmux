public import WebKit

/// Who made the opaque documents (`data:`, `about:` and `blob:` of an
/// opaque origin) of a web view's frames.
@MainActor
public final class BrowserReplDocumentProvenance {
    /// Records the navigation WebKit asks about in `webView`.
    public static func note(_ action: WKNavigationAction, in webView: WKWebView) {}
}
