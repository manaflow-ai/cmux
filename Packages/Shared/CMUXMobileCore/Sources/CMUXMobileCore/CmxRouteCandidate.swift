import Foundation

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

/// A single reachability hint for a paired Mac: a route plus where it came from
/// and when it was last seen. Candidates from every source are unioned, deduped
/// by endpoint, and ranked into the order the phone tries them in by
/// ``CmxRouteCandidateSet``.
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

    /// Stable identity used to dedup candidates. Includes the transport `kind`
    /// so two routes to the SAME address over different transports — e.g. a
    /// `debug_loopback` and a `tailscale` route at the same host:port — stay
    /// distinct candidates. The reconnect path filters by supported kind, so
    /// collapsing them by address alone could drop the only supported route.
    public var dedupKey: String { "\(route.kind.rawValue)|\(route.endpoint.routeDedupKey)" }
}
