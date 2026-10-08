import CmuxNextPages
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// Reports the pooled React page hosts and claim/build timings (`debug.page_host_pool`).
@MainActor
enum DebugPageHostPool {
    static func handle(_ params: [String: JSONValue], services: AppServices?) -> JSONValue {
        guard let services else { return .null }
        let pool = services.pageHostPool
        if params["action"]?.stringValue == "drop" { pool.dropSpare() }
        let claims: [JSONValue] = pool.claims.map { claim in
            .object(["page": .string(claim.page), "cross_window": .bool(claim.crossWindow),
                     "spare": .bool(claim.spare), "ms": .number(claim.milliseconds)])
        }
        let spans: [JSONValue] = pool.spans.map {
            .object(["name": .string($0.name), "ms": .number($0.milliseconds)])
        }
        // How each claimed host took its claim (acknowledged without a reload, or the fallback).
        let outcomes: [JSONValue] = pool.claimedHosts.compactMap { host in
            host.lastClaim.map { .object(["page": .string(host.pageID), "path": .string($0.path.rawValue), "ms": .number($0.milliseconds)]) }
        }
        return [
            "claim_outcomes": .array(outcomes),
            "likely": .bool(pool.isLikely),
            "building": .bool(pool.isBuilding),
            "spare_ready": .bool(pool.isSpareReady),
            "host_count": .number(Double(pool.hostCount)),
            "claimed": .number(Double(pool.claimedHosts.count)),
            "target_window": pool.target.map { .number(Double($0.windowNumber)) } ?? .null,
            "claims": .array(claims),
            "spans": .array(spans),
        ]
    }
}
