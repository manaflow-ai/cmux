public import Foundation

import CFNetwork
import CmuxCore

/// Rewrites a webView URL so the user-facing chrome (omnibar, session history,
/// restoration snapshots) shows a localhost-family host instead of the loopback
/// proxy's alias host.
///
/// When a remote workspace's browser loads over the loopback proxy, WebKit's
/// `webView.url` carries the proxy alias host (`RemoteLoopbackProxyAlias.aliasHost`).
/// Surfacing that alias to the user would leak an internal hostname, so every
/// display path routes the live URL through ``displayURL(for:)`` to map the alias
/// back to its localhost-family host (`localhost`, `127.0.0.1`, etc.). URLs that
/// are not alias-hosted pass through unchanged.
///
/// The resolver carries no state and delegates host classification to
/// `RemoteLoopbackProxyAlias` (the single source of truth in `CmuxCore`), so it is
/// a `Sendable` value type rather than a static-method namespace.
public struct BrowserRemoteProxyURLResolver: Sendable {
    /// Creates a resolver.
    public init() {}

    /// Returns `url` with its alias proxy host rewritten to the matching
    /// localhost-family host for display, or the input unchanged when `url` is
    /// `nil`, has no host, or is not an alias host.
    public func displayURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        guard let host = RemoteLoopbackProxyAlias.normalizeHost(url.host ?? "") else { return url }
        guard let displayHost = RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = displayHost
        return components?.url ?? url
    }

    /// Returns an ephemeral `URLSession` whose connections are tunneled through the
    /// remote workspace's SOCKS proxy at `endpoint`, or `nil` when the endpoint host
    /// is blank or the port is outside `1...65535`.
    ///
    /// The session is short-timeout (2s request, 4s resource) and cache-preferring,
    /// matching the favicon-fetch path that drove its creation. Callers own the
    /// returned session and must invalidate it (`finishTasksAndInvalidate()`).
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

    /// Returns `url` with its loopback host rewritten to the proxy alias host so the
    /// request resolves through the loopback proxy, or `nil` when `url` is not an
    /// `http` URL, has no host, or whose host is not a loopback-family host.
    ///
    /// This is the inbound counterpart to ``displayURL(for:)``: display maps the
    /// alias host back to `localhost`/`127.0.0.1` for the user, while this maps the
    /// localhost-family host forward to the alias host for the network request.
    public func loopbackAliasURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return nil }
        guard let host = RemoteLoopbackProxyAlias.normalizeHost(url.host ?? "") else { return nil }
        guard RemoteLoopbackProxyAlias.isLoopbackHost(host) else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = RemoteLoopbackProxyAlias.browserAliasHost(
            forLoopbackHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        )
        return components?.url
    }
}
