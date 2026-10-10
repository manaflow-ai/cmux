public import Foundation

/// The Vite dev server every React page loads from in Debug and tagged builds, so TypeScript and
/// CSS edits hot reload in the running app (`bun run dev:pages` in `webviews/`, then launch with
/// `CMUX_NEXT_PAGES_DEV_URL=http://127.0.0.1:4190/`). Release builds never read the variable.
///
/// The page keeps its own origin: ``PageSchemeHandler`` answers `cmux-page://<id>/<path>` with
/// the server's `/<path>`, so the host bridge, routing and trust (``PageHostTrust``) stay the
/// shipped ones. Only the page document maps to a dev path of its own (`/history/`,
/// `/diff-page.html`); dynamic prefixes (`__patch`, `backdrop`) stay with the page instance.
public nonisolated struct PageDevServer: Sendable, Equatable {
    /// Environment variable naming the server, for example `http://127.0.0.1:4190/`.
    public static let variable = "CMUX_NEXT_PAGES_DEV_URL"

    #if DEBUG
    static let allowed = true
    #else
    static let allowed = false
    #endif

    /// This process's server: nil in Release, or without a valid ``variable``.
    public static let current = resolve(environment: ProcessInfo.processInfo.environment, allowsDevServer: allowed)

    /// The pages the server serves: the React pages and the three viewers. The agent pane has its
    /// own override (`CMUX_NEXT_AGENT_PANE_DEV_URL`); an app page is never served from it.
    static let pageIDs: Set<String> = [
        "cmux.apps", "cmux.changelog", "cmux.cloud", "cmux.coderouter", "cmux.debug-settings", "cmux.diff", "cmux.editor", "cmux.history", "cmux.home-channels",
        "cmux.icon-picker", "cmux.keybindings", "cmux.markdown", "cmux.passwords", "cmux.settings",
    ]

    /// The server's root URL (`http://127.0.0.1:4190/`).
    public let root: URL

    /// The server ``variable`` names, when `allowsDevServer` (false in Release) and it passes
    /// ``loopbackURL(_:)``.
    public static func resolve(environment: [String: String], allowsDevServer: Bool) -> PageDevServer? {
        guard allowsDevServer, let value = environment[variable], let root = loopbackURL(value) else { return nil }
        return PageDevServer(root: root)
    }

    /// `string` as a dev server root, or nil unless it is a loopback `http` origin with an
    /// explicit port and no credentials: the page it serves gets the page's host access, so no
    /// other host may serve it. Path and query are kept, a fragment is dropped. The agent pane
    /// override (`AgentPaneSource`) uses the same rule.
    public static func loopbackURL(_ string: String) -> URL? {
        guard var components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http",
              let host = components.host, ["127.0.0.1", "localhost"].contains(host.lowercased()),
              components.port != nil,
              components.user == nil, components.password == nil
        else { return nil }
        components.scheme = "http"
        components.host = host.lowercased()
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    /// `<host>:<port>`.
    var authority: String { "\(root.host ?? ""):\(root.port ?? 0)" }

    /// The server URL for a request of `page`; nil when the page or the path is not the server's
    /// (another origin, a page outside ``pageIDs``, a dynamic prefix, `.` or `..`).
    func url(for request: URL, page: PageDescriptor) -> URL? {
        guard Self.pageIDs.contains(page.id.lowercased()), page.owns(request) else { return nil }
        let components = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        if let first = components.first, page.dynamicPrefixes.contains(first) { return nil }
        var base = root.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        // The document: a shared build's entry html, else the dev server's page route.
        if components.isEmpty || components == [page.entry] {
            return URL(string: base + (page.entry == "index.html" ? "/\(page.resource)/" : "/\(page.entry)"))
        }
        let path = URLComponents(url: request, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? request.path
        let query = URLComponents(url: request, resolvingAgainstBaseURL: false)?.percentEncodedQuery.map { "?" + $0 } ?? ""
        return URL(string: base + path + query)
    }

    /// The page's policy plus the server: the Vite client's HMR socket and its reconnect ping.
    func csp(for page: PageDescriptor) -> PageCSP {
        var csp = page.csp
        csp.connect += ["ws://" + authority, "http://" + authority]
        return csp
    }

    /// Whether `response` still comes from this server; a redirect elsewhere is refused.
    func isOwn(_ response: URL?) -> Bool {
        guard let response else { return false }
        return response.scheme?.lowercased() == "http" && response.host?.lowercased() == root.host
            && response.port == root.port
    }

    /// One uncached GET from the server.
    @concurrent static func fetch(_ url: URL) async -> (Data, HTTPURLResponse)? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }
}
