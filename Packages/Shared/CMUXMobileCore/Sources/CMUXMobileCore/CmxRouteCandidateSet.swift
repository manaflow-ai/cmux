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
    /// 1. **Dedup by transport + endpoint:** when several sources name the same
    ///    endpoint over the same transport kind, keep the freshest (tie → higher
    ///    source authority → lower route priority). Two transports to the same
    ///    address stay distinct so a kind filter downstream can't be starved.
    /// 2. **Rank** the survivors by freshness (newest first), then source
    ///    authority (registry over local cache), then proximity (closest first),
    ///    then the route's own `priority`, then a stable key.
    ///
    /// Freshness and source authority rank *above* proximity and `route.priority`
    /// so a fresh, authoritative registry route always sorts ahead of a
    /// possibly-stale cached one — even a closer (e.g. cached LAN) one. The
    /// reconnect path dials the first route, so ranking a stale-but-closer route
    /// first would keep failing on it. Among equally-fresh routes from the same
    /// source, proximity (then the Mac-assigned `priority`) decides.
    ///
    /// - Parameters:
    ///   - preferLoopback: When `true` (e.g. the simulator, where `127.0.0.1`
    ///     reaches the Mac), loopback routes rank first; when `false` (a
    ///     physical phone, where loopback can only reach itself) they rank last.
    ///   - maxCandidates: Optional upper bound on the result count after ranking.
    ///     `nil` (the default) is **unbounded** so the merge stays additive — it
    ///     never silently evicts a lower-ranked offline-cache fallback. A caller
    ///     that genuinely needs a cap opts in; the lowest-ranked candidates are
    ///     dropped first, so a cap can drop offline-cache routes (rank them
    ///     before capping if they must survive). `0` yields an empty result.
    public func merged(
        preferLoopback: Bool = false,
        maxCandidates: Int? = nil
    ) -> [CmxRouteCandidate] {
        let ranked = deduped().sorted { Self.sortsBefore($0, $1, preferLoopback: preferLoopback) }
        // No cap requested (nil) or a negative cap: return the full additive set.
        // A zero cap yields an empty result; a positive cap truncates after
        // ranking, dropping the worst-ranked candidates.
        guard let maxCandidates, maxCandidates >= 0 else { return ranked }
        guard ranked.count > maxCandidates else { return ranked }
        return Array(ranked.prefix(maxCandidates))
    }

    /// The candidates deduped by transport + endpoint (keeping the best per key
    /// via the same tiebreak as ``merged(preferLoopback:maxCandidates:)``), in
    /// first-seen order — **without** proximity/freshness re-ranking.
    ///
    /// Use this when the consumer imposes its own dial order and only needs
    /// duplicate endpoints collapsed. The single-route reconnect path is one such
    /// consumer: it dials by the Mac-assigned route `priority` (the Mac's own
    /// reachability hint), so re-ranking by proximity here would be discarded —
    /// and a proximity order is only safe once the dial path *tries candidates in
    /// order*, which is what ``merged(preferLoopback:maxCandidates:)`` is the
    /// foundation for.
    public func deduped() -> [CmxRouteCandidate] {
        guard !candidates.isEmpty else { return [] }
        var bestByKey: [String: CmxRouteCandidate] = [:]
        var keyOrder: [String] = []
        for candidate in candidates {
            let key = candidate.dedupKey
            if let existing = bestByKey[key] {
                if Self.prefersAsDedupWinner(candidate, over: existing) {
                    bestByKey[key] = candidate
                }
            } else {
                bestByKey[key] = candidate
                keyOrder.append(key)
            }
        }
        return keyOrder.compactMap { bestByKey[$0] }
    }

    /// ``deduped()`` projected back to plain routes in first-seen order.
    public func dedupedRoutes() -> [CmxAttachRoute] {
        deduped().map(\.route)
    }

    /// Convenience: ``merged(preferLoopback:maxCandidates:)`` projected back to
    /// plain routes in tried order, dropping the candidate metadata.
    public func mergedRoutes(
        preferLoopback: Bool = false,
        maxCandidates: Int? = nil
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

    /// Total ordering for the ranked candidate list: freshness, then source
    /// authority, then proximity, then the Mac-assigned priority, then a stable
    /// key. Freshness/authority lead so a fresh registry route outranks a stale
    /// cached one regardless of how close the stale one is.
    private static func sortsBefore(
        _ lhs: CmxRouteCandidate,
        _ rhs: CmxRouteCandidate,
        preferLoopback: Bool
    ) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        if lhs.source.authority != rhs.source.authority {
            return lhs.source.authority > rhs.source.authority
        }
        let lhsTier = proximityRank(lhs.proximity, preferLoopback: preferLoopback)
        let rhsTier = proximityRank(rhs.proximity, preferLoopback: preferLoopback)
        if lhsTier != rhsTier { return lhsTier < rhsTier }
        if lhs.route.priority != rhs.route.priority { return lhs.route.priority < rhs.route.priority }
        return lhs.dedupKey < rhs.dedupKey
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
