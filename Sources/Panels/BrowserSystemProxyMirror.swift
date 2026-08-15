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
/// mode, LAN proxy box). macOS bypasses the system proxy for the bare
/// `localhost` hostname but not for `*.localhost` subdomains (its proxy
/// exception matching is exact, not suffix-based), so subdomain-routed dev
/// servers like `tenant.localhost:PORT` stay broken even when `localhost`
/// works (#5703). Mirroring an active system proxy into explicit configurations
/// keeps normal traffic on a faithfully representable proxy while the whole
/// loopback family (including `*.localhost`) connects directly, matching
/// Chromium's implicit proxy-bypass rules.
/// https://github.com/manaflow-ai/cmux/issues/5888
/// https://github.com/manaflow-ai/cmux/issues/5703
struct BrowserSystemProxyMirror: Equatable {
    /// A system proxy expressible as a Network.framework `ProxyConfiguration`.
    ///
    /// `ProxyConfiguration` routes every non-excluded connection the same way,
    /// so the mirror only claims a system proxy that one configuration can
    /// represent for browser (HTTP/HTTPS) traffic:
    /// - `socksV5`: a SOCKSv5 proxy with no web proxy enabled.
    /// - `httpCONNECT`: a matched HTTP+HTTPS system web proxy on a *loopback*
    ///   endpoint — both enabled and pointing at the same local address (the
    ///   common Clash/Surge/mihomo mixed-port setup on `127.0.0.1`). It is
    ///   mirrored as a CONNECT proxy so the loopback family can be excluded and
    ///   `*.localhost` reaches local dev servers directly (#5703). Because
    ///   CONNECT forces tunneling for plain-HTTP loads and cannot carry
    ///   system-managed credentials, this is scoped to loopback proxy tools the
    ///   user runs locally; a remote/corporate web proxy, or an HTTP-only,
    ///   HTTPS-only, or split web proxy, is still declined (see `init?`).
    enum Proxy: Equatable {
        case socksV5(host: String, port: UInt16)
        case httpCONNECT(host: String, port: UInt16)
    }

    /// The proxy every non-excluded connection should use.
    let proxy: Proxy

    /// Hostname suffixes that bypass the proxy: the implicit defaults merged
    /// with the expressible entries of the user's macOS proxy bypass list.
    let excludedDomains: [String]

    /// Hosts that always connect directly, mirroring Chromium's implicit
    /// proxy-bypass rules: localhost (and subdomains), the canonical
    /// IPv4/IPv6 loopback literals, mDNS `.local` names, and the link-local
    /// credential-bearing metadata endpoints (`169.254.169.254` IMDS and
    /// `169.254.170.2` ECS task credentials; the broader `169.254/16`
    /// system bypass is not representable — see
    /// `init?(systemProxySettings:)`). Entries are domain suffixes, so
    /// `"local"` covers `*.local`.
    static let implicitExclusions: [String] = [
        "localhost", "127.0.0.1", "::1", "local", "169.254.169.254", "169.254.170.2",
    ]

    /// Maps a `CFNetworkCopySystemProxySettings()` dictionary to an explicit
    /// proxy + bypass mirror, or `nil` when the active configuration cannot
    /// be represented faithfully.
    ///
    /// The mirror fails closed: whenever any part of the system policy —
    /// proxy routing or bypass rules — has no `ProxyConfiguration`
    /// equivalent, no mirror is produced and WebKit keeps following the
    /// system proxy unchanged. The one exception is the link-local CIDR
    /// `169.254/16`, which macOS ships in the default bypass list of every
    /// network service: treating it as blocking would disable the loopback
    /// fix on effectively every Mac, so it is skipped instead. Literal
    /// link-local URLs (e.g. `http://169.254.169.254` metadata endpoints)
    /// are the only flow that loses its bypass, and only when no other
    /// unrepresentable rule already declines the mirror — any deliberately
    /// curated CIDR list still fails closed.
    init?(systemProxySettings settings: [String: Any]) {
        // PAC files and WPAD evaluate a script per URL; they cannot be
        // expressed as static ProxyConfiguration values, so the system keeps
        // handling them (current behavior, no loopback bypass).
        guard !Self.isEnabled(kCFNetworkProxiesProxyAutoConfigEnable, in: settings),
              !Self.isEnabled(kCFNetworkProxiesProxyAutoDiscoveryEnable, in: settings) else {
            return nil
        }

        // "Exclude simple hostnames" bypasses every dot-less hostname; a
        // hostname-suffix exclusion list cannot express that, so decline
        // rather than silently routing those hosts to the proxy.
        guard !Self.isEnabled(kCFNetworkProxiesExcludeSimpleHostnames, in: settings) else {
            return nil
        }

        // Resolve the single proxy that represents the system policy for
        // browser traffic (a matched web proxy as CONNECT, otherwise SOCKS), or
        // decline when no `ProxyConfiguration` can express it.
        guard let resolvedProxy = Self.resolveProxy(in: settings) else {
            return nil
        }
        proxy = resolvedProxy

        let bypassList = (settings[kCFNetworkProxiesExceptionsList as String] as? [Any] ?? [])
            .compactMap { $0 as? String }
        guard let merged = Self.mergedExcludedDomains(systemBypassList: bypassList) else {
            return nil
        }
        excludedDomains = merged
    }

    private static func isEnabled(_ key: CFString, in settings: [String: Any]) -> Bool {
        (settings[key as String] as? NSNumber)?.boolValue ?? false
    }

    private static func endpoint(
        in settings: [String: Any],
        enableKey: CFString,
        hostKey: CFString,
        portKey: CFString
    ) -> (host: String, port: UInt16)? {
        guard isEnabled(enableKey, in: settings) else { return nil }
        guard let host = (settings[hostKey as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !host.isEmpty else { return nil }
        guard let port = (settings[portKey as String] as? NSNumber)?.intValue,
              port > 0, port <= 65535 else { return nil }
        return (host: host, port: UInt16(port))
    }

    /// Resolves the system proxy settings to the single proxy that represents
    /// the policy for browser (HTTP/HTTPS) traffic, or `nil` when no
    /// `ProxyConfiguration` can express it.
    ///
    /// A system web proxy takes precedence — it is what the system uses for
    /// HTTP/HTTPS — but it is mirrored only when it is a matched HTTP+HTTPS pair
    /// pointing at one **loopback** endpoint. That scopes the CONNECT mirror to
    /// local proxy tools the user runs on this Mac (Clash/Surge/mihomo in "set
    /// as system proxy" mode), which are reachable and — being general-purpose
    /// tunnels with HTTPS already enabled — support CONNECT.
    ///
    /// The accepted residual (#5703): a *loopback* proxy that is forward-only or
    /// requires client credentials would see ordinary `http://` loads tunneled
    /// via CONNECT without auth. That is rare for a localhost proxy and is the
    /// deliberate trade for reaching `*.localhost` dev servers at all; it cannot
    /// be detected from the settings dictionary (no CONNECT-capability or
    /// credential keys), so it is not gated further. A remote or corporate web
    /// proxy — where forward-only routing and authentication are common — is
    /// left on WebKit's native system-proxy path (#5959). An HTTP-only,
    /// HTTPS-only, or split web proxy is likewise unrepresentable and declines,
    /// even when a SOCKS proxy is also configured. With no web proxy, a SOCKS
    /// proxy (which faithfully tunnels every scheme) is mirrored directly.
    private static func resolveProxy(in settings: [String: Any]) -> Proxy? {
        let httpEnabled = isEnabled(kCFNetworkProxiesHTTPEnable, in: settings)
        let httpsEnabled = isEnabled(kCFNetworkProxiesHTTPSEnable, in: settings)
        if httpEnabled || httpsEnabled {
            guard httpEnabled, httpsEnabled,
                  let http = endpoint(
                      in: settings,
                      enableKey: kCFNetworkProxiesHTTPEnable,
                      hostKey: kCFNetworkProxiesHTTPProxy,
                      portKey: kCFNetworkProxiesHTTPPort
                  ),
                  let https = endpoint(
                      in: settings,
                      enableKey: kCFNetworkProxiesHTTPSEnable,
                      hostKey: kCFNetworkProxiesHTTPSProxy,
                      portKey: kCFNetworkProxiesHTTPSPort
                  ),
                  http.host.caseInsensitiveCompare(https.host) == .orderedSame,
                  http.port == https.port,
                  isLoopbackProxyHost(http.host) else {
                return nil
            }
            return .httpCONNECT(host: http.host, port: http.port)
        }
        if let socks = endpoint(
            in: settings,
            enableKey: kCFNetworkProxiesSOCKSEnable,
            hostKey: kCFNetworkProxiesSOCKSProxy,
            portKey: kCFNetworkProxiesSOCKSPort
        ) {
            return .socksV5(host: socks.host, port: socks.port)
        }
        return nil
    }

    /// Whether a proxy endpoint host is loopback (this Mac). Used to scope the
    /// web-proxy CONNECT mirror to local proxy tools the user runs themselves;
    /// see `resolveProxy(in:)`. Covers `localhost`, the IPv6 loopback `::1`
    /// (with or without brackets), and the `127.0.0.0/8` IPv4 loopback block.
    private static func isLoopbackProxyHost(_ host: String) -> Bool {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if value == "localhost" || value == "::1" { return true }
        // 127.0.0.0/8: require a real dotted-quad IPv4 literal whose first octet
        // is 127, so a DNS name like "127.proxy.corp.example" is not loopback.
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let parsedOctets = octets.compactMap { UInt8($0) }
        return parsedOctets.count == 4 && parsedOctets[0] == 127
    }

    /// How a single system bypass-list entry maps onto `excludedDomains`.
    private enum BypassEntryResolution {
        /// Expressible as a hostname-suffix exclusion.
        case domain(String)
        /// The macOS default link-local CIDR; skipped without blocking the
        /// mirror (see `init?(systemProxySettings:)`).
        case ignorableDefault
        /// Whitespace or wildcard-only fragments that express no bypass
        /// intent; skipped without blocking the mirror.
        case noise
        /// A deliberate bypass rule with no hostname-suffix equivalent
        /// (CIDR ranges, non-leading wildcards); declines the whole mirror
        /// so the system policy keeps being honored.
        case unrepresentable
    }

    /// Merges the loopback defaults with the user's macOS bypass list
    /// ("Bypass proxy settings for these Hosts & Domains"), or returns `nil`
    /// when the list contains a deliberate rule that hostname-suffix
    /// exclusions cannot express. Leading `*.` / `.` prefixes are normalized
    /// away (`*.local` → `local`), entries are lowercased and deduplicated.
    private static func mergedExcludedDomains(systemBypassList: [String]) -> [String]? {
        var seen = Set(implicitExclusions)
        var merged = implicitExclusions
        for rawEntry in systemBypassList {
            switch resolveBypassEntry(rawEntry) {
            case .domain(let entry):
                if seen.insert(entry).inserted {
                    merged.append(entry)
                }
            case .ignorableDefault, .noise:
                continue
            case .unrepresentable:
                return nil
            }
        }
        return merged
    }

    private static func resolveBypassEntry(_ rawEntry: String) -> BypassEntryResolution {
        let trimmed = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return .noise
        }
        if trimmed == "169.254/16" || trimmed == "169.254.0.0/16" {
            return .ignorableDefault
        }

        var entry = trimmed
        if entry.hasPrefix("*.") {
            entry.removeFirst(2)
        }
        while entry.hasPrefix(".") {
            entry.removeFirst()
        }
        if entry.isEmpty {
            return .noise
        }
        if entry.contains("/") || entry.contains("*") {
            return .unrepresentable
        }
        return .domain(entry)
    }
}

extension BrowserSystemProxyMirror {
    /// Reads the live macOS proxy settings and builds the configurations a
    /// local-workspace `WKWebsiteDataStore` should use: the mirrored system
    /// proxy with loopback excluded, or empty — WebKit's system-proxy
    /// fallback, unchanged behavior — when no faithful mirror exists.
    static func currentProxyConfigurations() -> [ProxyConfiguration] {
        guard let rawSettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
            return []
        }
        guard let settings = rawSettings as NSDictionary as? [String: Any],
              let mirror = BrowserSystemProxyMirror(systemProxySettings: settings) else {
            return []
        }
        return mirror.proxyConfigurations()
    }

    /// Builds the Network.framework configurations to set on a
    /// `WKWebsiteDataStore`.
    ///
    /// Failover stays disabled (the platform default) so the mirror keeps the
    /// system proxy's semantics: traffic meant for the proxy never silently
    /// falls back to a direct connection.
    func proxyConfigurations() -> [ProxyConfiguration] {
        let host: String
        let port: UInt16
        let makeConfiguration: (NWEndpoint) -> ProxyConfiguration
        switch proxy {
        case .socksV5(let proxyHost, let proxyPort):
            host = proxyHost
            port = proxyPort
            makeConfiguration = { ProxyConfiguration(socksv5Proxy: $0) }
        case .httpCONNECT(let proxyHost, let proxyPort):
            host = proxyHost
            port = proxyPort
            makeConfiguration = { ProxyConfiguration(httpCONNECTProxy: $0) }
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return [] }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        var configuration = makeConfiguration(endpoint)
        configuration.excludedDomains = excludedDomains
        return [configuration]
    }
}
