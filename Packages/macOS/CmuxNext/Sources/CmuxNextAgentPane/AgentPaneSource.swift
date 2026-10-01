public import Foundation
import WebKit

/// Where an agent pane's page comes from.
public nonisolated enum AgentPaneSource: Equatable, Sendable {
    /// The self-contained `index.html` in the module bundle.
    case bundled(URL)
    /// A Vite dev server on loopback, by its root URL.
    case devServer(URL)

    /// Environment variable naming the dev server.
    public static let devURLVariable = "CMUX_NEXT_AGENT_PANE_DEV_URL"

    /// The page to load.
    public static func resolve(environment: [String: String], bundledPage: URL?, allowsDevServer: Bool) -> AgentPaneSource? {
        bundledPage.map { .bundled($0) }
    }

    /// True when `url` is this source's page.
    func isTrusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        switch self {
        case .bundled(let page):
            guard url.isFileURL else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == page.standardizedFileURL.resolvingSymlinksInPath().path
        case .devServer:
            return false
        }
    }

    /// Navigates `webView` to the page.
    @MainActor func load(into webView: WKWebView) {
        switch self {
        case .bundled(let page):
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        case .devServer(let url):
            webView.load(URLRequest(url: url))
        }
    }
}
