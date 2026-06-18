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
/// configurations keeps normal traffic on a faithfully representable proxy
/// while loopback connects directly, matching Chromium's implicit proxy-bypass
/// rules.
/// https://github.com/manaflow-ai/cmux/issues/5888
struct BrowserSystemProxyMirror: Equatable {
    /// A system proxy expressible as a Network.framework `ProxyConfiguration`.
    ///
    /// `ProxyConfiguration` routes every non-excluded connection the same way.
    /// The mirror therefore only claims SOCKSv5 settings with no web proxy
    /// enabled. HTTP and HTTPS system web proxies are ordinary forward-proxy
    /// settings; Network.framework's HTTP CONNECT configuration is not a
    /// faithful replacement for that policy, so those settings are never
    /// mirrored and WebKit keeps its default system-proxy behavior.
    enum Proxy: Equatable {
        case socksV5(host: String, port: UInt16)
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

        // System web proxies are forward-proxy settings. Mapping them to
        // `ProxyConfiguration(httpCONNECTProxy:)` would force CONNECT
        // semantics for ordinary HTTP loads and can lose system-managed proxy
        // authentication, so leave WebKit on its native system-proxy path.
        guard !Self.isEnabled(kCFNetworkProxiesHTTPEnable, in: settings),
              !Self.isEnabled(kCFNetworkProxiesHTTPSEnable, in: settings) else {
            return nil
        }

        if let socks = Self.endpoint(
            in: settings,
            enableKey: kCFNetworkProxiesSOCKSEnable,
            hostKey: kCFNetworkProxiesSOCKSProxy,
            portKey: kCFNetworkProxiesSOCKSPort
        ) {
            proxy = .socksV5(host: socks.host, port: socks.port)
        } else {
            return nil
        }

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
        switch proxy {
        case .socksV5(let proxyHost, let proxyPort):
            host = proxyHost
            port = proxyPort
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return [] }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        var configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        configuration.excludedDomains = excludedDomains
        return [configuration]
    }
}
