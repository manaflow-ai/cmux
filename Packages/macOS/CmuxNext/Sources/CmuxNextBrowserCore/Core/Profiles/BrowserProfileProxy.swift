public import Foundation
public import Network

/// A browser profile's own proxy (#24432): every page of the profile, in
/// either engine, exits through it; a profile without one stays direct.
///
/// The record holds no secret. An upstream that needs credentials goes
/// behind a local relay (`127.0.0.1:PORT`) the profile points at, so no
/// password reaches cmux's records, exports, CLI output or logs.
///
/// Both engines fail closed: Chromium gets one fixed server and no direct
/// fallback, WebKit one proxy configuration on the profile's data store, so a
/// dead proxy shows a proxy error instead of loading over the direct path.
///
/// ```swift
/// let proxy = BrowserProfileProxy(scheme: .socks5, host: "127.0.0.1", port: 1080)
/// proxy.chromiumServer // "socks5://127.0.0.1:1080"
/// ```
public nonisolated struct BrowserProfileProxy: Codable, Hashable, Sendable {
    /// How the engines talk to the proxy.
    public enum Scheme: String, Codable, Hashable, Sendable, CaseIterable {
        /// An HTTP proxy (CONNECT for HTTPS pages).
        case http
        /// An HTTP proxy reached over TLS.
        case https
        /// A SOCKS5 proxy; host names resolve at the proxy.
        case socks5
    }

    /// How the engines talk to the proxy.
    public var scheme: Scheme
    /// The proxy's host name or IP address (no brackets for IPv6).
    public var host: String
    /// The proxy's port, 1-65535.
    public var port: Int
    /// Hosts that skip the proxy (Chromium bypass rules, e.g. `*.corp.test`); empty: none.
    public var bypass: [String]

    /// - Parameters:
    ///   - scheme: how the engines talk to the proxy.
    ///   - host: the proxy's host name or IP address.
    ///   - port: the proxy's port.
    ///   - bypass: hosts that skip the proxy (default none).
    public init(scheme: Scheme, host: String, port: Int, bypass: [String] = []) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.bypass = bypass
    }

    /// The host as a URL authority writes it: an IPv6 address in brackets.
    package var authorityHost: String { host.contains(":") ? "[\(host)]" : host }

    /// Chromium's `proxy.server` preference value: `scheme://host:port`.
    public var chromiumServer: String { "\(scheme.rawValue)://\(authorityHost):\(port)" }

    /// Chromium's `proxy.bypass_list` preference value: the bypass rules, `;`-separated.
    public var chromiumBypassList: String { bypass.joined(separator: ";") }

    /// The WebKit proxy configuration of this proxy, nil when its port is out of range.
    @available(macOS 14.0, *)
    public var webKitConfiguration: ProxyConfiguration? {
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        var configuration = switch scheme {
        case .http: ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .https: ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        case .socks5: ProxyConfiguration(socksv5Proxy: endpoint)
        }
        // A dead proxy fails closed instead of going direct.
        configuration.allowFailover = false
        if !bypass.isEmpty { configuration.excludedDomains = bypass.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 } }
        return configuration
    }
}
