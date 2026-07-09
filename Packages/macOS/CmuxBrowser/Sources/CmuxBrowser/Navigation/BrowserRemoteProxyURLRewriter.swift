public import Foundation
internal import CmuxCore

/// Rewrites URLs between the user-facing localhost family and the browser's
/// remote-loopback proxy alias host.
///
/// ``displayURL(for:)`` maps a proxy-alias host back to its localhost-family
/// host for display, and ``loopbackAliasURL(for:)`` maps a plaintext loopback
/// URL to its alias host so it can route through the remote proxy. Both are
/// pure transforms layered over ``RemoteLoopbackProxyAlias`` and
/// ``BrowserInsecureHTTPSettings/normalizeHost(_:)``.
///
/// Static members only: stateless URL transforms with no per-instance state.
/// lint:allow namespace-type — stateless URL-rewrite transforms, no per-instance
/// state (no-namespace-enum carve-out).
public struct BrowserRemoteProxyURLRewriter {
    /// Maps a proxy-alias host in `url` back to its localhost-family host for
    /// display, returning `url` unchanged when it is not an alias URL and `nil`
    /// when `url` is `nil`.
    public static func displayURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return url }
        guard let displayHost = RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = displayHost
        return components?.url ?? url
    }

    /// Maps a plaintext `http://` loopback `url` to its proxy-alias host so it
    /// routes through the remote loopback proxy, returning `nil` when `url` is
    /// not an eligible loopback URL.
    public static func loopbackAliasURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return nil }
        guard RemoteLoopbackProxyAlias.isLoopbackHost(host) else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = RemoteLoopbackProxyAlias.browserAliasHost(
            forLoopbackHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        )
        return components?.url
    }
}
