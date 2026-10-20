import WebKit

/// Puts new agent pages (the New Tab page, agent chats) into shared web content processes, at
/// most ``pagesPerProcess`` pages per process (plans/cmux-next/sequoia-lag.md).
@MainActor
final class WebProcessGroups {
    /// The most pages one web content process serves.
    let pagesPerProcess: Int

    /// - Parameter pagesPerProcess: The most pages one process serves (at least 1).
    init(pagesPerProcess: Int = 8) {
        self.pagesPerProcess = max(pagesPerProcess, 1)
    }

    /// Makes the page's web view with `make` from `configuration`.
    func webView(for configuration: WKWebViewConfiguration, make: (WKWebViewConfiguration) -> WKWebView) -> WKWebView {
        make(configuration)
    }
}
