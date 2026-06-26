import Foundation

/// Network-distance tier for an attach route's endpoint.
///
/// The phone reaches a paired Mac through several transports of varying
/// closeness. When the same Mac advertises more than one reachable endpoint,
/// the closest one should be tried first: a direct same-network address is the
/// lowest latency and needs no relay, a Tailnet address works anywhere the
/// tailnet does, and a relay hop is the last resort. This is the proximity half
/// of issue #6351's "ranks by freshness + proximity (direct LAN > Tailnet >
/// relay)".
///
/// Classification is purely a function of the *endpoint address*, never the
/// route's declared ``CmxAttachTransportKind``: a `tailscale`-kind route may
/// carry a raw CGNAT IP, a MagicDNS hostname, or (in principle) any host, so the
/// address is the reliable signal. ``loopback`` is its own tier rather than the
/// closest LAN tier because a loopback address only reaches the host it runs on
/// — useful on the simulator (where `127.0.0.1` *is* the Mac) but never on a
/// physical phone; callers express that policy via `preferLoopback`.
public enum CmxRouteProximity: Sendable, Equatable, CaseIterable {
    /// `127.0.0.0/8` or `::1` — the same host (simulator / on-device mock host).
    case loopback
    /// An RFC1918 / link-local / unique-local IP literal — direct same-network.
    case lan
    /// Tailscale CGNAT (`100.64.0.0/10`), its IPv6 ULA (`fd7a:115c:a1e0::/48`),
    /// or a MagicDNS `*.ts.net` hostname.
    case tailnet
    /// An iroh peer, a websocket URL, or any other globally-routable / named
    /// host — reachable, but not provably local or on the tailnet.
    case relay
    /// An endpoint that could not be classified (empty/garbage host).
    case unknown

    /// Classify an endpoint into its proximity tier from its address alone.
    public static func classify(_ endpoint: CmxAttachEndpoint) -> CmxRouteProximity {
        switch endpoint {
        case let .hostPort(host, _):
            return classifyHost(host)
        case .peer:
            // iroh peers connect through a relay / hole-punch; treat as far.
            return .relay
        case .url:
            // A websocket relay URL is a far transport by construction.
            return .relay
        }
    }

    /// Classify a `host` string (IPv4/IPv6 literal or hostname).
    static func classifyHost(_ host: String) -> CmxRouteProximity {
        let trimmed = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")) // strip IPv6 brackets
            .lowercased()
        guard !trimmed.isEmpty else { return .unknown }

        if trimmed == "localhost" || trimmed.hasSuffix(".localhost") {
            return .loopback
        }
        if trimmed.contains(":") {
            return classifyIPv6(trimmed)
        }
        if let octets = ipv4Octets(trimmed) {
            return classifyIPv4(octets)
        }
        // A bare hostname: Tailscale MagicDNS names are tailnet; everything else
        // needs general DNS resolution and is treated as a far (relay) host.
        if trimmed.hasSuffix(".ts.net") {
            return .tailnet
        }
        return .relay
    }

    /// Parse a canonical dotted-decimal IPv4 literal into its four octets, or
    /// `nil` if `host` is not one. Rejects leading zeros / out-of-range parts so
    /// only genuine IPv4 literals classify as such (matches the phone's existing
    /// `isIPLiteralHost` discipline).
    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  let value = Int(part),
                  (0...255).contains(value),
                  String(value) == part else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func classifyIPv4(_ octets: [Int]) -> CmxRouteProximity {
        // 127.0.0.0/8
        if octets[0] == 127 { return .loopback }
        // 169.254.0.0/16 link-local
        if octets[0] == 169, octets[1] == 254 { return .lan }
        // RFC1918 private ranges.
        if octets[0] == 10 { return .lan }
        if octets[0] == 172, (16...31).contains(octets[1]) { return .lan }
        if octets[0] == 192, octets[1] == 168 { return .lan }
        // 100.64.0.0/10 — Tailscale's CGNAT range.
        if octets[0] == 100, (64...127).contains(octets[1]) { return .tailnet }
        // Any other literal is globally routable: dialable but not local/tailnet.
        return .relay
    }

    private static func classifyIPv6(_ host: String) -> CmxRouteProximity {
        if host == "::1" { return .loopback }
        // Tailscale's IPv6 ULA prefix fd7a:115c:a1e0::/48 — check before generic
        // ULA so a Tailscale v6 address ranks as tailnet, not plain LAN.
        if host.hasPrefix("fd7a:115c:a1e0") { return .tailnet }
        // fe80::/10 link-local: first 10 bits 1111111010, i.e. the leading
        // hextet spans fe80–febf, so match fe8x / fe9x / feax / febx.
        if host.hasPrefix("fe8") || host.hasPrefix("fe9")
            || host.hasPrefix("fea") || host.hasPrefix("feb") {
            return .lan
        }
        // fc00::/7 unique-local (fc.. / fd..).
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return .lan }
        return .relay
    }
}
