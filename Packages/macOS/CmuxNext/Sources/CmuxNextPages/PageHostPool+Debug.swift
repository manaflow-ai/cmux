public import CmuxNextSettings

extension PageHostPool {
    /// `debug.page_host_pool`: the pooled React page hosts and their claim and build timings. `action: drop` drops
    /// the spare first; `release_idle` frees it as the idle limit does; `intent` runs ``noteIntent()``.
    public func debugReport(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue {
        case "drop": dropSpare()
        case "release_idle": releaseIdle()
        case "intent": noteIntent()
        default: break
        }
        let claims: [JSONValue] = self.claims.map { claim in
            .object(["page": .string(claim.page), "cross_window": .bool(claim.crossWindow),
                     "spare": .bool(claim.spare), "ms": .number(claim.milliseconds)])
        }
        let spans: [JSONValue] = self.spans.map {
            .object(["name": .string($0.name), "ms": .number($0.milliseconds)])
        }
        // How each claimed host took its claim (acknowledged without a reload, or the fallback).
        let outcomes: [JSONValue] = claimedHosts.compactMap { host in
            host.lastClaim.map { .object(["page": .string(host.pageID), "path": .string($0.path.rawValue), "ms": .number($0.milliseconds)]) }
        }
        return [
            "claim_outcomes": .array(outcomes),
            "likely": .bool(isLikely),
            "building": .bool(isBuilding),
            "spare_ready": .bool(isSpareReady),
            "host_count": .number(Double(hostCount)),
            "claimed": .number(Double(claimedHosts.count)),
            "idle_limit_s": idleLimit.map { .number(Double($0.components.seconds)) } ?? .null,
            "target_window": target.map { .number(Double($0.windowNumber)) } ?? .null,
            "claims": .array(claims),
            "spans": .array(spans),
        ]
    }

    /// Claims that took the spare so far (`debug.page_open_bench`).
    public var spareClaims: Int { claims.filter(\.spare).count }
}
