import Foundation

/// A versioned, flat agent-session graph suitable for CLI automation.
struct AgentSessionGraphSnapshot: Codable, Sendable, Equatable {
    var schemaVersion: Int = 2
    var nodes: [AgentSessionGraphNode]
    var edges: [AgentSessionGraphEdge]
    var storeWarnings: [AgentHookSessionStoreLoadWarning]? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case nodes
        case edges
        case storeWarnings = "store_warnings"
    }
}

enum AgentSessionGraphOrdering {
    static func nodePrecedes(_ lhs: AgentSessionGraphNode, _ rhs: AgentSessionGraphNode) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        if lhs.runId != rhs.runId { return lhs.runId < rhs.runId }
        return lhs.nodeId < rhs.nodeId
    }

    static func edgePrecedes(_ lhs: AgentSessionGraphEdge, _ rhs: AgentSessionGraphEdge) -> Bool {
        if lhs.toNodeId != rhs.toNodeId { return lhs.toNodeId < rhs.toNodeId }
        if lhs.relationship != rhs.relationship {
            return lhs.relationship.rawValue < rhs.relationship.rawValue
        }
        if lhs.toRunId != rhs.toRunId { return lhs.toRunId < rhs.toRunId }
        if let result = optionalStringPrecedes(lhs.fromRunId, rhs.fromRunId) { return result }
        if let result = optionalStringPrecedes(lhs.fromSessionId, rhs.fromSessionId) { return result }
        return false
    }

    private static func optionalStringPrecedes(_ lhs: String?, _ rhs: String?) -> Bool? {
        if lhs == rhs { return nil }
        guard let lhs else { return true }
        guard let rhs else { return false }
        return lhs < rhs
    }
}

enum AgentSessionRunCanonicalizer {
    static func runs(
        record: ClaudeHookSessionRecord,
        provider: String
    ) -> [AgentSessionRunRecord] {
        let rawRuns = if let runs = record.runs, !runs.isEmpty {
            runs
        } else {
            [AgentSessionRunRecord(
                runId: record.runId ?? "session:\(provider):\(record.sessionId)",
                pid: record.pid,
                processStartedAt: nil,
                cmuxRuntime: record.cmuxRuntime,
                parentRunId: record.parentRunId,
                parentSessionId: record.parentSessionId,
                relationship: record.relationship,
                restoreAuthority: record.restoreAuthority ?? (record.relationship != .spawned),
                startedAt: record.startedAt,
                updatedAt: record.updatedAt,
                endedAt: record.completedAt
            )]
        }
        var newestByRunID: [String: AgentSessionRunRecord] = [:]
        newestByRunID.reserveCapacity(rawRuns.count)
        for run in rawRuns {
            if let current = newestByRunID[run.runId] {
                if isNewer(run, than: current) {
                    newestByRunID[run.runId] = run
                }
            } else {
                newestByRunID[run.runId] = run
            }
        }
        return newestByRunID.values.sorted { $0.runId < $1.runId }
    }

    static func projectedRun(
        record: ClaudeHookSessionRecord,
        provider: String
    ) -> AgentSessionRunRecord {
        let canonicalRuns = runs(record: record, provider: provider)
        if let activeRunID = record.activeRunId,
           let active = canonicalRuns.first(where: { $0.runId == activeRunID }) {
            return active
        }
        return canonicalRuns.dropFirst().reduce(canonicalRuns[0]) { newest, candidate in
            isNewer(candidate, than: newest) ? candidate : newest
        }
    }

    private static func isNewer(
        _ candidate: AgentSessionRunRecord,
        than current: AgentSessionRunRecord
    ) -> Bool {
        if candidate.updatedAt != current.updatedAt { return candidate.updatedAt > current.updatedAt }
        if candidate.startedAt != current.startedAt { return candidate.startedAt > current.startedAt }
        if (candidate.endedAt == nil) != (current.endedAt == nil) { return candidate.endedAt == nil }
        if candidate.endedAt != current.endedAt {
            return (candidate.endedAt ?? -.infinity) > (current.endedAt ?? -.infinity)
        }
        if candidate.processStartedAt != current.processStartedAt {
            return (candidate.processStartedAt ?? -.infinity) > (current.processStartedAt ?? -.infinity)
        }
        if candidate.pid != current.pid { return (candidate.pid ?? -1) > (current.pid ?? -1) }
        if let result = optionalStringPrecedes(candidate.cmuxRuntime?.id, current.cmuxRuntime?.id) {
            return result
        }
        if let result = optionalStringPrecedes(
            candidate.cmuxRuntime?.socketPath,
            current.cmuxRuntime?.socketPath
        ) {
            return result
        }
        if let result = optionalStringPrecedes(
            candidate.cmuxRuntime?.bundleIdentifier,
            current.cmuxRuntime?.bundleIdentifier
        ) {
            return result
        }
        if let result = optionalStringPrecedes(candidate.parentRunId, current.parentRunId) {
            return result
        }
        if let result = optionalStringPrecedes(candidate.parentSessionId, current.parentSessionId) {
            return result
        }
        if let result = optionalStringPrecedes(
            candidate.relationship?.rawValue,
            current.relationship?.rawValue
        ) {
            return result
        }
        if let result = optionalStringPrecedes(
            candidate.authorityEvidence?.rawValue,
            current.authorityEvidence?.rawValue
        ) {
            return result
        }
        if candidate.restoreAuthority != current.restoreAuthority { return candidate.restoreAuthority }
        return false
    }

    private static func optionalStringPrecedes(_ lhs: String?, _ rhs: String?) -> Bool? {
        if lhs == rhs { return nil }
        guard let lhs else { return true }
        guard let rhs else { return false }
        return lhs < rhs
    }
}
