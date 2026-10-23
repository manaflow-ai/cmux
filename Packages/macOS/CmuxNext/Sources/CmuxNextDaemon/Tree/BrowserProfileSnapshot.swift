import Foundation

/// One browser profile record of the home session (`browser-profiles-v1`,
/// plans/cmux-next/data-model.md section 5). Wire shape
/// (`list-personal.browser_profiles[]`): `{id, name, color, icon, index,
/// source, proxy?}`; `id` is `default` or a lowercase UUID.
public struct BrowserProfileSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    public var name: String
    public var color: String?
    public var icon: String?
    public var index: Int
    /// Import origin (`browser`, `profile_dir`, `display_name`), or nil.
    public var source: [String: String]?
    /// The profile's proxy (#24432), nil when direct.
    public var proxy: Proxy?

    /// A profile's proxy as the daemon stores it (no secret): `{scheme, host, port, bypass?}`.
    public struct Proxy: Sendable, Hashable, Decodable {
        /// `http`, `https` or `socks5`.
        public var scheme: String
        public var host: String
        public var port: Int
        /// Hosts that skip the proxy; empty when absent.
        public var bypass: [String]

        public init(scheme: String, host: String, port: Int, bypass: [String] = []) {
            self.scheme = scheme
            self.host = host
            self.port = port
            self.bypass = bypass
        }

        enum CodingKeys: String, CodingKey { case scheme, host, port, bypass }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scheme = try c.decode(String.self, forKey: .scheme)
            host = try c.decode(String.self, forKey: .host)
            port = try c.decode(Int.self, forKey: .port)
            bypass = try c.decodeIfPresent([String].self, forKey: .bypass) ?? []
        }
    }

    public init(id: String, name: String, color: String? = nil, icon: String? = nil, index: Int = 0, source: [String: String]? = nil,
                proxy: Proxy? = nil) {
        self.proxy = proxy
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.index = index
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, name, color, icon, index, source, proxy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        // Only string members are kept; another shape is ignored.
        source = (try? c.decodeIfPresent([String: String].self, forKey: .source)) ?? nil
        proxy = try c.decodeIfPresent(Proxy.self, forKey: .proxy)
    }
}
