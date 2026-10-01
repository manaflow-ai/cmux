import AppKit
import CmuxNextDesign
import WebKit

/// Home's content: the mux Messages app (mux/apps/web) in a web view. The
/// page keeps its own session (website data persists), so sign-in survives
/// relaunch. A native Messages view can replace this view behind the same
/// `HomePresenter` without touching the window.
final class HomeView: NSView {
    let webView: WKWebView

    init(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.autoresizingMask = [.width, .height]
        webView.setAccessibilityLabel(HomeStrings.title)
        addSubview(webView)
        webView.load(URLRequest(url: url))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView.frame = bounds
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
}

/// Where Home loads mux from. `CMUX_NEXT_MUX_URL` overrides the default
/// (staging until mux has a production deployment).
enum HomeLocation {
    static let defaultURL = URL(string: "https://mux-staging.debussy.workers.dev")!

    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let override = environment["CMUX_NEXT_MUX_URL"].flatMap(URL.init(string:)),
              override.scheme == "https" || override.scheme == "http" else { return defaultURL }
        return override
    }
}

enum HomeStrings {
    static var title: String { String(localized: "home.title", defaultValue: "Home", bundle: .module) }
}
