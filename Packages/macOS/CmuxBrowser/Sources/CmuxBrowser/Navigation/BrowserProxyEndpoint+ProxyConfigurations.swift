public import Network

import CmuxCore

extension BrowserProxyEndpoint {
    /// Builds the Network.framework configurations a remote-workspace
    /// `WKWebsiteDataStore` should use to route the embedded browser through
    /// this loopback proxy endpoint.
    ///
    /// The host is trimmed of surrounding whitespace and the port is validated
    /// against the `1...65535` range and `NWEndpoint.Port`; an empty host or an
    /// out-of-range port yields `[]`, matching the legacy fall-closed behavior
    /// (WebKit then makes no proxied connection while the endpoint is invalid).
    /// A valid endpoint produces the SOCKSv5 + HTTP CONNECT pair, mirroring the
    /// `socksv5Proxy`/`httpCONNECTProxy` shape `BrowserSystemProxyMirror` uses
    /// for the local-workspace mirror.
    public func proxyConfigurations() -> [ProxyConfiguration] {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              port > 0 && port <= 65535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return []
        }

        let nwEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmedHost), port: nwPort)
        let socks = ProxyConfiguration(socksv5Proxy: nwEndpoint)
        let connect = ProxyConfiguration(httpCONNECTProxy: nwEndpoint)
        return [socks, connect]
    }
}
