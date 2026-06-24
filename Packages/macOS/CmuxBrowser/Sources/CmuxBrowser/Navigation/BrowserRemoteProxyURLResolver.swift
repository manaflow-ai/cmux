public import Foundation

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
}
