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
        // fe80::/10 link-local.
        if host.hasPrefix("fe80") { return .lan }
        // fc00::/7 unique-local (fc.. / fd..).
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return .lan }
        return .relay
    }
}

extension CmxAttachEndpoint {
    /// Stable dedup identity for this endpoint, independent of the route `id`,
    /// `priority`, or which source advertised it. Two routes with the same
    /// host:port, the same peer id, or the same URL are the same physical
    /// destination and collapse to one candidate.
    ///
    /// Only the host of a `hostPort` is case-folded (hostnames and IPv6 literals
    /// are case-insensitive). Peer ids and URLs are kept case-sensitive: URL
    /// path/query may carry case-sensitive relay route ids or tokens, and peer
    /// ids are opaque case-sensitive identifiers — lowercasing either could
    /// collapse two distinct endpoints and discard a valid route.
    public var routeDedupKey: String {
        switch self {
        case let .hostPort(host, port):
            let normalized = host
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased()
            return "hp|\(normalized)|\(port)"
        case let .peer(id, _, _, _):
            return "peer|\(id.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .url(url):
            return "url|\(url.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Where a route candidate came from. Used as a freshness/trust tiebreaker when
/// two sources advertise the same endpoint: the cloud registry is authoritative
/// when reachable, a freshly scanned QR is current by construction, and the
/// offline local cache is the least authoritative (it may be stale).
public enum CmxRouteSource: String, Codable, Sendable, CaseIterable {
    /// A freshly scanned pairing QR / attach ticket.
    case qr
    /// A manually entered IP:port.
    case manual
    /// The team-scoped server device registry (`/api/devices`).
    case registry
    /// The phone's persisted offline cache and write-back buffer.
    case localCache
    /// Future LAN mDNS / Bonjour discovery.
    case mdns

    /// Higher wins when two candidates for the *same* endpoint are equally
    /// fresh. The registry is authoritative when reachable; the local cache is
    /// the offline fallback and ranks lowest.
    var authority: Int {
        switch self {
        case .registry: return 4
        case .qr: return 3
        case .manual: return 2
        case .mdns: return 1
        case .localCache: return 0
        }
    }
}

/// A single reachability hint for a paired Mac: a route plus where it came from
/// and when it was last seen. Candidates from every source are unioned, deduped
/// by endpoint, and ranked into the order the phone tries them in.
public struct CmxRouteCandidate: Equatable, Sendable {
    public let route: CmxAttachRoute
    public let source: CmxRouteSource
    /// When this candidate was last observed/refreshed. Drives freshness
    /// ranking; newer is preferred within a proximity tier.
    public let lastSeenAt: Date

    public init(route: CmxAttachRoute, source: CmxRouteSource, lastSeenAt: Date) {
        self.route = route
        self.source = source
        self.lastSeenAt = lastSeenAt
    }

    /// The route's proximity tier, derived from its endpoint address.
    public var proximity: CmxRouteProximity { .classify(route.endpoint) }

    /// Stable identity used to dedup candidates that point at the same endpoint.
    public var endpointKey: String { route.endpoint.routeDedupKey }
}

/// A collection of route candidates gathered from every source (QR, registry,
/// local cache, …) that knows how to collapse itself into the single ordered
/// list the phone tries in order — issue #6351's "freshness-ranked candidate
/// set".
///
/// The merge is intentionally **additive**: routes are advisory hints and
/// connectivity is self-validating, so keeping a possibly-stale route (it fails
/// fast if dead) is strictly safer than dropping a route that still works. This
/// is the foundation for the server-death graceful fallback — a partial or
/// unreachable registry can only *add* candidates, never remove the locally
/// cached ones that let pairing survive offline.
public struct CmxRouteCandidateSet: Equatable, Sendable {
    /// Default upper bound on the merged candidate count, matching the server's
    /// per-instance route cap. Ranking runs first, so any truncation drops only
    /// the worst-ranked (stalest / farthest) candidates.
    public static let defaultMaxCandidates = 16

    /// The gathered candidates, in arbitrary order (deduped/ranked by ``merged``).
    public let candidates: [CmxRouteCandidate]

    public init(_ candidates: [CmxRouteCandidate] = []) {
        self.candidates = candidates
    }

    /// Build a set from raw routes of a single source, all stamped `lastSeenAt`.
    public init(routes: [CmxAttachRoute], source: CmxRouteSource, lastSeenAt: Date) {
        self.candidates = routes.map {
            CmxRouteCandidate(route: $0, source: source, lastSeenAt: lastSeenAt)
        }
    }

    /// A new set whose candidates are this set's followed by `other`'s. Dedup is
    /// deferred to ``merged(preferLoopback:maxCandidates:)``; ordering of the two
    /// operands only affects the stable first-seen order of equal-ranked dupes,
    /// so pass the more authoritative source first.
    public func unioned(with other: CmxRouteCandidateSet) -> CmxRouteCandidateSet {
        CmxRouteCandidateSet(candidates + other.candidates)
    }

    /// Collapse the gathered candidates into the order the phone should try them.
    ///
    /// 1. **Dedup by endpoint:** when several sources name the same endpoint,
    ///    keep the freshest (tie → higher source authority → lower route
    ///    priority).
    /// 2. **Rank** the survivors by proximity (closest first), then freshness
    ///    (newest first), then the route's own `priority`, then source
    ///    authority, then a stable key.
    ///
    /// - Parameters:
    ///   - preferLoopback: When `true` (e.g. the simulator, where `127.0.0.1`
    ///     reaches the Mac), loopback routes rank first; when `false` (a
    ///     physical phone, where loopback can only reach itself) they rank last.
    ///   - maxCandidates: Upper bound on the result count after ranking.
    public func merged(
        preferLoopback: Bool = false,
        maxCandidates: Int = CmxRouteCandidateSet.defaultMaxCandidates
    ) -> [CmxRouteCandidate] {
        guard !candidates.isEmpty else { return [] }

        var bestByKey: [String: CmxRouteCandidate] = [:]
        var keyOrder: [String] = []
        for candidate in candidates {
            let key = candidate.endpointKey
            if let existing = bestByKey[key] {
                if Self.prefersAsDedupWinner(candidate, over: existing) {
                    bestByKey[key] = candidate
                }
            } else {
                bestByKey[key] = candidate
                keyOrder.append(key)
            }
        }

        let deduped = keyOrder.compactMap { bestByKey[$0] }
        let ranked = deduped.sorted { Self.sortsBefore($0, $1, preferLoopback: preferLoopback) }
        guard maxCandidates > 0, ranked.count > maxCandidates else { return ranked }
        return Array(ranked.prefix(maxCandidates))
    }

    /// Convenience: ``merged(preferLoopback:maxCandidates:)`` projected back to
    /// plain routes in tried order, dropping the candidate metadata.
    public func mergedRoutes(
        preferLoopback: Bool = false,
        maxCandidates: Int = CmxRouteCandidateSet.defaultMaxCandidates
    ) -> [CmxAttachRoute] {
        merged(preferLoopback: preferLoopback, maxCandidates: maxCandidates).map(\.route)
    }

    // MARK: - Ordering

    /// Whether `lhs` should replace `rhs` as the kept candidate for one endpoint.
    private static func prefersAsDedupWinner(
        _ lhs: CmxRouteCandidate,
        over rhs: CmxRouteCandidate
    ) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        if lhs.source.authority != rhs.source.authority {
            return lhs.source.authority > rhs.source.authority
        }
        if lhs.route.priority != rhs.route.priority {
            return lhs.route.priority < rhs.route.priority
        }
        return false
    }

    /// Total ordering for the ranked candidate list.
    private static func sortsBefore(
        _ lhs: CmxRouteCandidate,
        _ rhs: CmxRouteCandidate,
        preferLoopback: Bool
    ) -> Bool {
        let lhsTier = proximityRank(lhs.proximity, preferLoopback: preferLoopback)
        let rhsTier = proximityRank(rhs.proximity, preferLoopback: preferLoopback)
        if lhsTier != rhsTier { return lhsTier < rhsTier }
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        if lhs.route.priority != rhs.route.priority { return lhs.route.priority < rhs.route.priority }
        if lhs.source.authority != rhs.source.authority {
            return lhs.source.authority > rhs.source.authority
        }
        return lhs.endpointKey < rhs.endpointKey
    }

    /// Sort weight for a proximity tier (lower = tried first). `preferLoopback`
    /// flips loopback between first (simulator) and last-before-unknown (device).
    private static func proximityRank(_ proximity: CmxRouteProximity, preferLoopback: Bool) -> Int {
        switch proximity {
        case .loopback: return preferLoopback ? 0 : 3
        case .lan: return preferLoopback ? 1 : 0
        case .tailnet: return preferLoopback ? 2 : 1
        case .relay: return preferLoopback ? 3 : 2
        case .unknown: return 4
        }
    }
}
