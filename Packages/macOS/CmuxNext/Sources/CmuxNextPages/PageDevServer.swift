import CryptoKit
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

    /// The pages the server serves: one per `webviews/src/pages/<resource>/` (``PageDevServerTests``
    /// keeps them equal). The agent pane has its own override (`CMUX_NEXT_AGENT_PANE_DEV_URL`); an
    /// app page is never served from it.
    static let pageIDs: Set<String> = [
        "cmux.apps", "cmux.artifacts", "cmux.changelog", "cmux.chief-inspector", "cmux.chief-usage", "cmux.chief-views", "cmux.cloud", "cmux.coderouter", "cmux.debug-settings", "cmux.diff", "cmux.editor", "cmux.files", "cmux.history", "cmux.home-channels",
        "cmux.icon-picker", "cmux.import-history", "cmux.keybindings", "cmux.markdown", "cmux.mobile-pairing", "cmux.passwords", "cmux.settings", "cmux.stats",
    ]

    /// The agent chat's page host (`cmux.agent`), which the server serves at `/agent-pane/` (the
    /// agent pane's dev entry, `AgentPaneSchemeHandler.devServerURL` for the legacy host). Not in
    /// ``pageIDs``, which lists `webviews/src/pages`; the live web loop serves it in either engine.
    static let agentPageID = "cmux.agent"

    /// The server's root URL (`http://127.0.0.1:4190/`).
    public let root: URL

    /// The secret the server proves itself with, nil for none. `web-dev.json` servers always have
    /// one (``WebDevOverride/parse(_:home:)``): every build reads that file, and a port a stale file
    /// names can be bound by any local process. Each request carries a fresh random
    /// ``nonceHeader``; only an answer whose ``proofHeader`` is HMAC-SHA256(token, nonce) counts as
    /// the user's server, so the token never crosses the wire and a recorded answer proves nothing.
    /// The Debug launch variable (``variable``) has none.
    public let token: String?

    /// The request header with the request's nonce.
    public static let nonceHeader = "X-Cmux-Dev-Nonce"
    /// The answer header with ``proof(token:nonce:)`` (`webviews/dev-server/plugins.ts` sets it).
    public static let proofHeader = "X-Cmux-Dev-Proof"

    public init(root: URL, token: String? = nil) {
        self.root = root
        self.token = token
    }

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
        let id = page.id.lowercased()
        guard Self.pageIDs.contains(id) || id == Self.agentPageID, page.owns(request) else { return nil }
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
        // Vite injects React Refresh as an inline module into entry HTML. This server is the Debug
        // launch variable's or web-dev.json's, whose answers prove its token (``answered(_:nonce:)``);
        // bundled page responses keep their policy.
        csp.inlineScript = true
        // 'none' stands alone in a source list: a page that opens no connection (the agent chat)
        // gets only the server's.
        csp.connect = csp.connect.filter { $0 != "'none'" } + ["ws://" + authority, "http://" + authority]
        return csp
    }

    /// Whether `response` still comes from this server; a redirect elsewhere is refused.
    public func isOwn(_ response: URL?) -> Bool {
        guard let response else { return false }
        return response.scheme?.lowercased() == "http" && response.host?.lowercased() == root.host
            && response.port == root.port
    }

    /// One uncached GET of `url` from this server, with a fresh nonce when it has a ``token``.
    public func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if token != nil {
            request.setValue(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.hexString, forHTTPHeaderField: Self.nonceHeader)
        }
        return request
    }

    /// Whether `response` to `request` (``request(for:)``) is this server's: from its origin
    /// (``isOwn(_:)``) and, when the server has a ``token``, proving it for the request's nonce.
    /// Anything else (another process on the port) falls through to the overlay or the bundle.
    public func answered(_ response: HTTPURLResponse, to request: URLRequest) -> Bool {
        guard isOwn(response.url) else { return false }
        guard let token else { return true }
        guard let nonce = request.value(forHTTPHeaderField: Self.nonceHeader), !nonce.isEmpty,
              let proof = response.value(forHTTPHeaderField: Self.proofHeader) else { return false }
        return proof.lowercased() == Self.proof(token: token, nonce: nonce)
    }

    /// HMAC-SHA256 of `nonce` keyed by `token`, as lowercase hex.
    public static func proof(token: String, nonce: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(token.utf8)))).hexString
    }

    /// Sends `request` (``request(for:)``).
    @concurrent public static func fetch(_ request: URLRequest) async -> (Data, HTTPURLResponse)? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
