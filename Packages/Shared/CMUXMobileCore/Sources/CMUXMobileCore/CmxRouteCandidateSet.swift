import Foundation

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
    ///    (newest first), then source authority (registry over local cache),
    ///    then the route's own `priority`, then a stable key.
    ///
    /// Source authority is ranked *above* `route.priority` so the authoritative
    /// registry route always wins over a possibly-stale cached one — otherwise a
    /// stale route with a lower (more-preferred) Mac priority could be dialed
    /// first and reconnect would keep failing on it. Within a single source,
    /// authority ties and the Mac-assigned `priority` decides.
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
        if lhs.source.authority != rhs.source.authority {
            return lhs.source.authority > rhs.source.authority
        }
        if lhs.route.priority != rhs.route.priority { return lhs.route.priority < rhs.route.priority }
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
