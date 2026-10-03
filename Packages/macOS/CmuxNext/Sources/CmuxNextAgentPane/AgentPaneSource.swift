public import Foundation
import WebKit

/// Where an agent pane's page comes from.
///
/// Release builds only ever load ``bundled(_:)``, the self-contained page that
/// `scripts/cmux-next/build-agent-pane-web.sh` builds into the module bundle.
/// Debug and tagged builds may instead load the pane from a Vite dev server on
/// loopback (``devServer(_:)``, `bun run dev:agent-pane` in `webviews/`), so
/// TypeScript edits hot-reload in the running app. The handshake still comes
/// from Swift, so the dev page talks to the real acpmux daemon.
///
/// ```swift
/// #if DEBUG
/// let allowsDevServer = true
/// #else
/// let allowsDevServer = false
/// #endif
/// let source = AgentPaneSource.resolve(
///     environment: ProcessInfo.processInfo.environment,
///     bundledPage: AgentPaneView.bundledPage,
///     allowsDevServer: allowsDevServer
/// )
/// ```
public nonisolated enum AgentPaneSource: Equatable, Sendable {
    /// The self-contained `index.html` in the module bundle.
    case bundled(URL)
    /// A Vite dev server on loopback, by its root URL
    /// (`http://127.0.0.1:<port>/`).
    case devServer(URL)

    /// The scheme and host the bundled page loads from (`AgentPaneSchemeHandler`):
    /// a real origin, `cmux-agent://pane`, where a `file://` page would send
    /// `Origin: null` to acpmux.
    public static let bundledScheme = "cmux-agent"
    public static let bundledHost = "pane"
    public static let bundledOrigin = "\(bundledScheme)://\(bundledHost)"

    /// The URL the web view loads: the bundled page under the cmux-agent
    /// origin, or the dev server's root.
    public var pageURL: URL {
        switch self {
        case .bundled(let page):
            URL(string: "\(Self.bundledOrigin)/\(page.lastPathComponent)")!
        case .devServer(let url):
            url
        }
    }

    /// Environment variable naming the dev server, for example
    /// `http://127.0.0.1:4176/`.
    public static let devURLVariable = "CMUX_NEXT_AGENT_PANE_DEV_URL"

    /// The page to load.
    ///
    /// - Parameters:
    ///   - environment: The process environment; ``devURLVariable`` names a
    ///     dev server.
    ///   - bundledPage: The bundled page, nil when the bundle lacks it.
    ///   - allowsDevServer: False in Release builds, so only the bundled page
    ///     loads there whatever the environment says.
    /// - Returns: The dev server when it is allowed and the override is an
    ///   `http` URL on 127.0.0.1 or localhost with an explicit port and no
    ///   credentials; otherwise the bundled page, or nil when it is missing.
    public static func resolve(environment: [String: String], bundledPage: URL?, allowsDevServer: Bool) -> AgentPaneSource? {
        if allowsDevServer, let override = environment[devURLVariable], let url = devServerURL(override) {
            return .devServer(url)
        }
        return bundledPage.map { .bundled($0) }
    }

    /// The dev server's root URL, or nil unless `string` is a loopback `http`
    /// origin: the page receives the daemon token, so no other host may serve
    /// it. Path and query are kept, a fragment is dropped.
    static func devServerURL(_ string: String) -> URL? {
        guard var components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http",
              let host = components.host, AcpmuxWebEndpoint.isLoopback(host),
              components.port != nil,
              components.user == nil, components.password == nil
        else { return nil }
        components.scheme = "http"
        components.host = host.lowercased()
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    /// True when `url` is this source's page: the bundled page under
    /// `cmux-agent://pane` (a `#fragment` allowed), or any URL on the dev
    /// server's exact origin (scheme, host and port).
    func isTrusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        switch self {
        case .bundled(let page):
            guard url.scheme?.lowercased() == Self.bundledScheme, url.host?.lowercased() == Self.bundledHost,
                  url.port == nil, url.user == nil
            else { return false }
            return url.path == "/" + page.lastPathComponent
        case .devServer(let root):
            guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let origin = URLComponents(url: root, resolvingAgainstBaseURL: false),
                  candidate.scheme?.lowercased() == "http",
                  let host = candidate.host, host.lowercased() == origin.host?.lowercased(),
                  let port = candidate.port, port == origin.port
            else { return false }
            return true
        }
    }

    /// Serves the bundled page's directory on `configuration` (before the
    /// web view is made from it); the dev server needs nothing.
    @MainActor func register(on configuration: WKWebViewConfiguration) {
        guard case .bundled(let page) = self else { return }
        configuration.setURLSchemeHandler(AgentPaneSchemeHandler(root: page.deletingLastPathComponent()), forURLScheme: Self.bundledScheme)
    }

    /// Navigates `webView` to the page.
    @MainActor func load(into webView: WKWebView) {
        switch self {
        case .bundled:
            webView.load(URLRequest(url: pageURL))
        case .devServer(let url):
            webView.load(URLRequest(url: url))
        }
    }
}
