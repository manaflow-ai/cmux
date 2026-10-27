public import CmuxNextBrowserCore
public import Network

nonisolated extension BrowserProfileProxy {
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
