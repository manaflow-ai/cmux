import AppKit
import WebKit

/// Builds script-free WebViews backed by an explicitly supplied data store.
@MainActor
struct ArtifactHTMLPreviewWebViewFactory {
    let websiteDataStore: WKWebsiteDataStore

    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    func makeWebView() -> CmuxWebView {
        let webView = CmuxWebView(
            frame: .zero,
            configuration: makeConfiguration()
        )
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        if #available(macOS 13.3, *) {
            webView.isInspectable = false
        }
        return webView
    }
}
