import CFNetwork
import Foundation
import Network

/// An explicit browser proxy mirrored from the macOS system proxy settings,
/// with hostname exclusions so loopback and proxy-bypass-list hosts connect
/// directly instead of being forwarded to the proxy.
///
/// WebKit, unlike Chromium, has no implicit loopback bypass: when a
/// `WKWebsiteDataStore` has no explicit `proxyConfigurations`, every request —
/// including `http://localhost:PORT` — follows the macOS system proxy and
/// fails whenever that proxy is not running on this Mac (Clash/Surge global
/// mode, LAN proxy box). Mirroring an active system proxy into explicit
/// configurations keeps normal traffic on the proxy while loopback connects
/// directly, matching Chromium's implicit proxy-bypass rules.
/// https://github.com/manaflow-ai/cmux/issues/5888
struct BrowserSystemProxyMirror: Equatable {
    /// A system proxy expressible as a Network.framework `ProxyConfiguration`.
    ///
    /// `ProxyConfiguration` models only HTTP CONNECT and SOCKSv5 proxies, and
    /// it routes every non-excluded connection the same way. The mirror
    /// therefore only claims a configuration it can represent faithfully:
    /// `httpCONNECT` requires the HTTP and HTTPS web proxies to be enabled
    /// with the identical endpoint (the global-proxy-tool shape), and
    /// `socksV5` requires SOCKS with no web proxy enabled at all. Anything
    /// else (PAC file, WPAD auto-discovery, HTTP-only, HTTPS-only, or split
    /// web-proxy endpoints) is never mirrored; the browser then keeps
    /// WebKit's default system-proxy behavior.
    enum Proxy: Equatable {
        case httpCONNECT(host: String, port: UInt16)
        case socksV5(host: String, port: UInt16)
    }

    /// The proxy every non-excluded connection should use.
    let proxy: Proxy

    /// Hostname suffixes that bypass the proxy: the loopback defaults merged
    /// with the expressible entries of the user's macOS proxy bypass list.
    let excludedDomains: [String]

    /// Hosts that always connect directly, mirroring Chromium's implicit
    /// proxy-bypass rules: localhost (and subdomains), the canonical
    /// IPv4/IPv6 loopback literals, and mDNS `.local` names. Entries are
    /// domain suffixes, so `"local"` covers `*.local`.
    static let loopbackExclusions: [String] = ["localhost", "127.0.0.1", "::1", "local"]

    /// Maps a `CFNetworkCopySystemProxySettings()` dictionary to an explicit
    /// proxy + bypass mirror, or `nil` when the active configuration cannot
    /// be represented faithfully.
    init?(systemProxySettings settings: [String: Any]) {
        // Mirroring is not implemented yet: local-workspace browser panes
        // currently always fall back to the system proxy, with no loopback
        // bypass (https://github.com/manaflow-ai/cmux/issues/5888).
        return nil
    }
}

extension BrowserSystemProxyMirror {
    /// Builds the Network.framework configurations to set on a
    /// `WKWebsiteDataStore`.
    ///
    /// Failover stays disabled (the platform default) so the mirror keeps the
    /// system proxy's semantics: traffic meant for the proxy never silently
    /// falls back to a direct connection.
    func proxyConfigurations() -> [ProxyConfiguration] {
        let host: String
        let port: UInt16
        switch proxy {
        case .httpCONNECT(let proxyHost, let proxyPort), .socksV5(let proxyHost, let proxyPort):
            host = proxyHost
            port = proxyPort
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return [] }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        var configuration: ProxyConfiguration
        switch proxy {
        case .httpCONNECT:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .socksV5:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        configuration.excludedDomains = excludedDomains
        return [configuration]
    }
}
