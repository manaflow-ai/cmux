import AppKit
import CmuxNextDesign
import WebKit

/// Home's content: the mux Messages app in a web view, by default from the
/// local mux server on this Mac (mux/local: acpmux agents, no sign-in). When
/// nothing answers, a native message says how to start it and offers Retry.
/// A native Messages view can replace this view behind `HomePresenter`.
final class HomeView: NSView, WKNavigationDelegate {
    let webView: WKWebView
    private let url: URL
    private let unavailable = HomeUnavailableView()

    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.setAccessibilityLabel(HomeStrings.title)
        addSubview(webView)
        unavailable.isHidden = true
        unavailable.onRetry = { [weak self] in self?.load() }
        addSubview(unavailable)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func load() {
        unavailable.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: url))
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        unavailable.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// Before the page paints (and past its edges) the window background shows.
    private func applyTheme() {
        performWithTheme { webView.underPageBackgroundColor = Palette.windowBackground }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        showUnavailable()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        showUnavailable()
    }

    private func showUnavailable() {
        webView.isHidden = true
        unavailable.isHidden = false
    }
}
