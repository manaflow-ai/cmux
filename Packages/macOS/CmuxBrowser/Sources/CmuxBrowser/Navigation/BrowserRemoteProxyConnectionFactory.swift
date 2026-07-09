public import Foundation
public import Network
public import CmuxCore
internal import CFNetwork

/// Builds the network connections an embedded browser pane needs to reach a
/// remote workspace through its loopback SOCKS proxy.
///
/// ``urlSession(for:)`` produces an ephemeral SOCKSv5 ``URLSession`` for
/// out-of-band fetches (favicons, etc.), and ``proxyConfigurations(for:)``
/// derives the ``ProxyConfiguration`` list a `WKWebsiteDataStore` applies so the
/// web view itself routes through the proxy. Both are pure transforms over a
/// ``BrowserProxyEndpoint`` value with no per-pane state; the caller owns the
/// live `WKWebView`/data-store assignment and any system-proxy fallback.
public struct BrowserRemoteProxyConnectionFactory: Sendable {
    /// Creates a connection factory.
    public init() {}

    /// Builds an ephemeral SOCKSv5 ``URLSession`` routed through `endpoint`, or
    /// `nil` when the endpoint's host/port is empty or out of range.
    public func urlSession(for endpoint: BrowserProxyEndpoint) -> URLSession? {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, endpoint.port > 0, endpoint.port <= 65535 else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 2.0
        configuration.timeoutIntervalForResource = 4.0
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: host,
            kCFNetworkProxiesSOCKSPort as String: endpoint.port,
        ]
        return URLSession(configuration: configuration)
    }

    /// Derives the SOCKSv5 + HTTP-CONNECT ``ProxyConfiguration`` pair for
    /// `endpoint`, returning an empty array when the endpoint's host/port is
    /// empty or out of range.
    public func proxyConfigurations(for endpoint: BrowserProxyEndpoint) -> [ProxyConfiguration] {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              endpoint.port > 0 && endpoint.port <= 65535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            return []
        }

        let nwEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let socks = ProxyConfiguration(socksv5Proxy: nwEndpoint)
        let connect = ProxyConfiguration(httpCONNECTProxy: nwEndpoint)
        return [socks, connect]
    }
}
