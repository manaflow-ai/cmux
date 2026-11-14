public import Foundation

/// Host-alias mapping between the localhost family and the public
/// `cmux-loopback.localtest.me` alias domain used by remote-workspace
/// browser proxying.
///
/// BrowserPanel rewrites loopback URLs to the alias domain so the SOCKS/
/// CONNECT proxy can recognize and route them; the loopback HTTP rewriters
/// and the daemon proxy tunnel map alias hosts back to true loopback before
/// dialing from the remote daemon.
///
/// Static members only: these are wire-affecting constants plus pure,
/// stateless host transforms shared by the app and the remote packages, so
/// there is no per-instance state to hold (one-line justification per the
/// no-namespace-enum convention).
public struct RemoteLoopbackProxyAlias {
    /// The alias domain substituted for loopback hosts in browser URLs.
    /// Wire/persisted value: do not rename.
    public static let aliasHost = "cmux-loopback.localtest.me"

    /// The canonical loopback host every alias maps back to.
    public static let canonicalLoopbackHost = "localhost"

    /// Hosts treated as exact loopback addresses (beyond `*.localhost`
    /// subdomains, which are matched by suffix).
    public static let exactLoopbackHosts: Set<String> = [
        canonicalLoopbackHost,
        "127.0.0.1",
        "::1",
        "0.0.0.0",
    ]

    /// Whether `host` is a loopback host (exact match or a `*.localhost`
    /// subdomain) after normalization.
    public static func isLoopbackHost(_ host: String) -> Bool {
        guard let normalizedHost = normalizeHost(host) else {
            return false
        }
        return exactLoopbackHosts.contains(normalizedHost)
            || normalizedHost.hasSuffix(".\(canonicalLoopbackHost)")
    }

    /// The alias host a browser should use for `host`, falling back to the
    /// bare alias when `host` is not in the localhost family.
    public static func browserAliasHost(forLoopbackHost host: String, aliasHost: String) -> String {
        localhostFamilyAliasHost(forLoopbackHost: host, aliasHost: aliasHost) ?? aliasHost
    }

    /// Maps an alias host (or alias subdomain) back to its localhost-family
    /// host, or `nil` when `host` does not belong to the alias domain.
    public static func localhostFamilyHost(forAliasHost host: String, aliasHost: String) -> String? {
        guard let normalizedHost = normalizeHost(host),
              let normalizedAlias = normalizeHost(aliasHost) else {
            return nil
        }
        if normalizedHost == normalizedAlias {
            return canonicalLoopbackHost
        }

        let suffix = ".\(normalizedAlias)"
        guard normalizedHost.hasSuffix(suffix) else { return nil }
        let prefix = String(normalizedHost.dropLast(suffix.count))
        guard !prefix.isEmpty else { return nil }
        return "\(prefix).\(canonicalLoopbackHost)"
    }

    /// Maps a localhost-family host (or `*.localhost` subdomain) to its alias
    /// host, or `nil` when `host` is not in the localhost family.
    public static func localhostFamilyAliasHost(forLoopbackHost host: String, aliasHost: String) -> String? {
        guard let normalizedHost = normalizeHost(host) else { return nil }
        if normalizedHost == canonicalLoopbackHost {
            return aliasHost
        }

        let suffix = ".\(canonicalLoopbackHost)"
        guard normalizedHost.hasSuffix(suffix) else { return nil }
        let prefix = String(normalizedHost.dropLast(suffix.count))
        guard !prefix.isEmpty else { return nil }
        return "\(prefix).\(aliasHost)"
    }

    /// The alias URL a remote-workspace browser should load instead of `url`,
    /// or `nil` when `url` must not be rewritten: non-`http` schemes,
    /// non-loopback hosts, and URLs on the app's own web origin
    /// (`exemptWebOrigin`).
    ///
    /// The exemption exists because pages served by the app's configured web
    /// endpoint (for example the Cloud VM desktop wrapper minted by
    /// `vm.open_port`) live on the HOST, not inside the remote workspace;
    /// aliasing them makes the remote daemon dial a port nothing serves
    /// there. It is keyed on the full origin (scheme, loopback-family host,
    /// effective port), so loopback previews of apps running inside the
    /// workspace keep proxying.
    public static func browserLoopbackAliasURL(for url: URL, exemptWebOrigin: URL?) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return nil }
        guard let host = normalizeHost(url.host ?? "") else { return nil }
        guard isLoopbackHost(host) else { return nil }
        if matchesWebOrigin(url, webOrigin: exemptWebOrigin) { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = browserAliasHost(forLoopbackHost: host, aliasHost: aliasHost)
        return components?.url
    }

    /// Whether `url` and `webOrigin` share a web origin (scheme, host,
    /// effective port) after collapsing the exact-loopback host family to
    /// ``canonicalLoopbackHost``. `*.localhost` subdomains stay distinct.
    private static func matchesWebOrigin(_ url: URL, webOrigin: URL?) -> Bool {
        guard let webOrigin,
              let urlScheme = url.scheme?.lowercased(),
              let originScheme = webOrigin.scheme?.lowercased(),
              urlScheme == originScheme,
              let urlHost = originComparableHost(url.host),
              let originHost = originComparableHost(webOrigin.host),
              urlHost == originHost else {
            return false
        }
        return effectivePort(of: url, scheme: urlScheme)
            == effectivePort(of: webOrigin, scheme: originScheme)
    }

    private static func originComparableHost(_ rawHost: String?) -> String? {
        guard let rawHost, let normalized = normalizeHost(rawHost) else { return nil }
        return exactLoopbackHosts.contains(normalized) ? canonicalLoopbackHost : normalized
    }

    private static func effectivePort(of url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    /// Normalizes a raw host string (possibly a URL, `host:port`, or
    /// bracketed IPv6 literal) to a bare lowercase host for comparison.
    ///
    /// Byte-identical lift of `BrowserInsecureHTTPSettings.normalizeHost`;
    /// the app-side copy should forward here once the integrator wires the
    /// import (single source of truth).
    public static func normalizeHost(_ rawHost: String) -> String? {
        var value = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return nil }

        if let parsed = URL(string: value)?.host {
            return trimHost(parsed)
        }

        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }

        if let slash = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            value = String(value[..<slash])
        }

        if value.hasPrefix("[") {
            if let closing = value.firstIndex(of: "]") {
                value = String(value[value.index(after: value.startIndex)..<closing])
            } else {
                value.removeFirst()
            }
        } else if let colon = value.lastIndex(of: ":"),
                  value[value.index(after: colon)...].allSatisfy(\.isNumber),
                  value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }

        return trimHost(value)
    }

    private static func trimHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }

        // Canonicalize IDN entries (e.g. bücher.example -> xn--bcher-kva.example)
        // so user-entered allowlist patterns compare against URL.host consistently.
        if let canonicalized = URL(string: "https://\(trimmed)")?.host {
            return canonicalized
        }

        return trimmed
    }
}
