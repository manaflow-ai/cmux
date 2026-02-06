import Foundation
import Combine
import WebKit
import AppKit

/// BrowserPanel provides a WKWebView-based browser panel.
/// All browser panels share a WKProcessPool for cookie sharing.
@MainActor
final class BrowserPanel: Panel, ObservableObject {
    /// Shared process pool for cookie sharing across all browser panels
    private static let sharedProcessPool = WKProcessPool()

    let id: UUID
    let panelType: PanelType = .browser

    /// The workspace ID this panel belongs to
    let workspaceId: UUID

    /// The underlying web view
    let webView: WKWebView

    /// Published URL being displayed
    @Published private(set) var currentURL: URL?

    /// Published page title
    @Published private(set) var pageTitle: String = ""

    /// Published loading state
    @Published private(set) var isLoading: Bool = false

    /// Published can go back state
    @Published private(set) var canGoBack: Bool = false

    /// Published can go forward state
    @Published private(set) var canGoForward: Bool = false

    /// Published estimated progress (0.0 - 1.0)
    @Published private(set) var estimatedProgress: Double = 0.0

    private var cancellables = Set<AnyCancellable>()
    private var navigationDelegate: BrowserNavigationDelegate?
    private var webViewObservers: [NSKeyValueObservation] = []

    var displayTitle: String {
        if !pageTitle.isEmpty {
            return pageTitle
        }
        if let url = currentURL {
            return url.host ?? url.absoluteString
        }
        return "Browser"
    }

    var displayIcon: String? {
        "globe"
    }

    var isDirty: Bool {
        false
    }

    init(workspaceId: UUID, initialURL: URL? = nil) {
        self.id = UUID()
        self.workspaceId = workspaceId

        // Configure web view
        let config = WKWebViewConfiguration()
        config.processPool = BrowserPanel.sharedProcessPool

        // Enable developer extras (DevTools)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Enable JavaScript
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Set up web view
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // Set modern Chrome user agent so sites don't serve degraded versions
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        self.webView = webView

        // Set up navigation delegate
        let navDelegate = BrowserNavigationDelegate()
        webView.navigationDelegate = navDelegate
        self.navigationDelegate = navDelegate

        // Observe web view properties
        setupObservers()

        // Navigate to initial URL if provided
        if let url = initialURL {
            navigate(to: url)
        }
    }

    private func setupObservers() {
        // URL changes
        let urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.currentURL = webView.url
            }
        }
        webViewObservers.append(urlObserver)

        // Title changes
        let titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.pageTitle = webView.title ?? ""
            }
        }
        webViewObservers.append(titleObserver)

        // Loading state
        let loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.isLoading = webView.isLoading
            }
        }
        webViewObservers.append(loadingObserver)

        // Can go back
        let backObserver = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.canGoBack = webView.canGoBack
            }
        }
        webViewObservers.append(backObserver)

        // Can go forward
        let forwardObserver = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.canGoForward = webView.canGoForward
            }
        }
        webViewObservers.append(forwardObserver)

        // Progress
        let progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.estimatedProgress = webView.estimatedProgress
            }
        }
        webViewObservers.append(progressObserver)
    }

    // MARK: - Panel Protocol

    func focus() {
        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }
        if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
            return
        }
        window.makeFirstResponder(webView)
    }

    func unfocus() {
        guard let window = webView.window else { return }
        if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
            window.makeFirstResponder(nil)
        }
    }

    func close() {
        // Ensure we don't keep a hidden WKWebView (or its content view) as first responder while
        // bonsplit/SwiftUI reshuffles views during close.
        unfocus()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        navigationDelegate = nil
        webViewObservers.removeAll()
    }

    // MARK: - Navigation

    /// Navigate to a URL
    func navigate(to url: URL) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    /// Navigate with smart URL/search detection
    /// - If input looks like a URL, navigate to it
    /// - Otherwise, perform a web search
    func navigateSmart(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = parseSmartInput(trimmed) {
            navigate(to: url)
        }
    }

    private func parseSmartInput(_ input: String) -> URL? {
        // Check if it's already a valid URL with scheme
        if let url = URL(string: input), url.scheme != nil {
            return url
        }

        // Check if it looks like a domain (contains a dot and no spaces)
        if input.contains(".") && !input.contains(" ") {
            // Try adding https://
            if let url = URL(string: "https://\(input)") {
                return url
            }
        }

        // Check for localhost
        if input.hasPrefix("localhost") || input.hasPrefix("127.0.0.1") {
            if let url = URL(string: "http://\(input)") {
                return url
            }
        }

        // Treat as a search query
        let encoded = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }

    /// Go back in history
    func goBack() {
        guard canGoBack else { return }
        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        webView.goForward()
    }

    /// Reload the current page
    func reload() {
        webView.reloadFromOrigin()
    }

    /// Stop loading
    func stopLoading() {
        webView.stopLoading()
    }

    /// Take a snapshot of the web view
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            if let error = error {
                NSLog("BrowserPanel snapshot error: %@", error.localizedDescription)
                completion(nil)
                return
            }
            completion(image)
        }
    }

    /// Execute JavaScript
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    deinit {
        webViewObservers.removeAll()
    }
}

// MARK: - Navigation Delegate

private class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Navigation started
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Navigation finished
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("BrowserPanel navigation failed: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("BrowserPanel provisional navigation failed: %@", error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Allow all navigation for now
        decisionHandler(.allow)
    }
}
