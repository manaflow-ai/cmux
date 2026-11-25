public import Foundation

/// One embedded external web app (`cmux.pane/1` `embed`) the daemon lets this client host
/// (`embed_pages` of its `apps-list` record). The daemon decided everything about it
/// (cmux-app-manifest `embed_pages`): the url, the origins the pane may navigate to (the url's
/// own first, then the declared ones, as `https://host` or `https://*.host`), and the browser
/// profile, a UUID derived from the app id so each app has its own cookies and sign-in.
public nonisolated struct AppEmbedPage: Sendable, Hashable {
    /// The interface the page implements (`cmux.pane/1`).
    public var interface: String
    public var url: URL
    public var origins: [String]
    /// The app's own browser profile: the identifier of its `WKWebsiteDataStore`.
    public var profile: UUID
    public var symbol: String?

    public init(interface: String, url: URL, origins: [String], profile: UUID, symbol: String? = nil) {
        self.interface = interface
        self.url = url
        self.origins = origins
        self.profile = profile
        self.symbol = symbol
    }

    init?(json: AppJSON) {
        guard let interface = json["interface"]?.stringValue,
              let url = json["url"]?.stringValue.flatMap(URL.init(string:)),
              let profile = json["profile"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
        self.init(interface: interface, url: url,
                  origins: json["origins"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                  profile: profile, symbol: json["symbol"]?.stringValue)
    }

    /// Whether the pane may navigate to `url`: the client side of cmux-app-manifest
    /// `embed_allows` (same rule, same tests): https on the default port, no credentials, and a
    /// host equal to an allowed origin's or under a `*.` origin's domain.
    public func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return origins.contains { origin in
            guard origin.hasPrefix("https://") else { return false }
            let allowed = String(origin.dropFirst("https://".count))
            if allowed.hasPrefix("*.") {
                let domain = String(allowed.dropFirst(2))
                return host.count > domain.count + 1 && host.hasSuffix("." + domain)
            }
            return host == allowed
        }
    }
}

public extension AppRecord {
    /// The app's own pane as an embedded web app (`cmux.pane/1` with `embed`), if the daemon hosts one.
    var embedPane: AppEmbedPage? { embedPages.first { $0.interface == AppImplementation.pane } }
}
