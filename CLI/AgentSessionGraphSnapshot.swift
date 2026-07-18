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

struct AgentSessionGraphOrdering: Sendable {
    func nodePrecedes(_ lhs: AgentSessionGraphNode, _ rhs: AgentSessionGraphNode) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        if lhs.runId != rhs.runId { return lhs.runId < rhs.runId }
        return lhs.nodeId < rhs.nodeId
    }

    func edgePrecedes(_ lhs: AgentSessionGraphEdge, _ rhs: AgentSessionGraphEdge) -> Bool {
        if lhs.toNodeId != rhs.toNodeId { return lhs.toNodeId < rhs.toNodeId }
        if lhs.relationship != rhs.relationship {
            return lhs.relationship.rawValue < rhs.relationship.rawValue
        }
        if lhs.toRunId != rhs.toRunId { return lhs.toRunId < rhs.toRunId }
        if let result = optionalStringPrecedes(lhs.fromRunId, rhs.fromRunId) { return result }
        if let result = optionalStringPrecedes(lhs.fromSessionId, rhs.fromSessionId) { return result }
        return false
    }

    private func optionalStringPrecedes(_ lhs: String?, _ rhs: String?) -> Bool? {
        if lhs == rhs { return nil }
        guard let lhs else { return true }
        guard let rhs else { return false }
        return lhs < rhs
    }
}

struct AgentSessionRunCanonicalizer: Sendable {
    func runs(
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
                newestByRunID[run.runId] = canonicalDuplicate(run, current)
            } else {
                newestByRunID[run.runId] = run
            }
        }
        return newestByRunID.values.sorted { $0.runId < $1.runId }
    }

    func projectedRun(
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

    private func isNewer(
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
        if candidate.restoreAuthority != current.restoreAuthority { return !candidate.restoreAuthority }
        return false
    }

    private func canonicalDuplicate(
        _ candidate: AgentSessionRunRecord,
        _ current: AgentSessionRunRecord
    ) -> AgentSessionRunRecord {
        guard candidate.updatedAt == current.updatedAt,
              candidate.startedAt == current.startedAt else {
            return isNewer(candidate, than: current) ? candidate : current
        }

        let preferred = isNewer(candidate, than: current) ? candidate : current
        let alternate = preferred == candidate ? current : candidate
        var merged = preferred
        // Equal-time duplicate writes describe one logical generation. Preserve
        // the strongest identity evidence while making restore ownership
        // monotonic, so corrupted ordering cannot promote a child into an owner.
        let processIdentityConflict = conflictingProcessIdentity(candidate, current)
        let runtimeIdentityConflict = conflictingRuntimeIdentity(candidate.cmuxRuntime, current.cmuxRuntime)
        let identityConflict = candidate.identityConflict == true
            || current.identityConflict == true
            || processIdentityConflict
            || runtimeIdentityConflict
        merged.identityConflict = identityConflict ? true : nil
        merged.restoreAuthority = candidate.restoreAuthority
            && current.restoreAuthority
            && !identityConflict
        if identityConflict {
            merged.pid = nil
            merged.processStartedAt = nil
            merged.cmuxRuntime = nil
        } else {
            // Keep PID/start metadata from one row as a coherent pair. Combining
            // complementary partial rows could invent a process generation that
            // neither writer actually observed.
            if preferred.pid != nil || preferred.processStartedAt != nil {
                merged.pid = preferred.pid
                merged.processStartedAt = preferred.processStartedAt
            } else {
                merged.pid = alternate.pid
                merged.processStartedAt = alternate.processStartedAt
            }
            merged.cmuxRuntime = preferredRuntime(candidate.cmuxRuntime, current.cmuxRuntime)
        }
        merged.parentRunId = preferred.parentRunId ?? alternate.parentRunId
        merged.parentSessionId = preferred.parentSessionId ?? alternate.parentSessionId
        if candidate.relationship == .spawned || current.relationship == .spawned {
            merged.relationship = .spawned
        } else {
            merged.relationship = preferred.relationship ?? alternate.relationship
        }
        merged.authorityEvidence = preferredAuthorityEvidence(
            candidate.authorityEvidence,
            current.authorityEvidence
        )
        if let candidateEndedAt = candidate.endedAt, let currentEndedAt = current.endedAt {
            merged.endedAt = max(candidateEndedAt, currentEndedAt)
        } else {
            merged.endedAt = candidate.endedAt ?? current.endedAt
        }
        if merged.endedAt != nil { merged.restoreAuthority = false }
        return merged
    }

    private func conflictingProcessIdentity(
        _ lhs: AgentSessionRunRecord,
        _ rhs: AgentSessionRunRecord
    ) -> Bool {
        if let lhsPID = lhs.pid, let rhsPID = rhs.pid, lhsPID != rhsPID { return true }
        if let lhsStartedAt = lhs.processStartedAt,
           let rhsStartedAt = rhs.processStartedAt,
           abs(lhsStartedAt - rhsStartedAt) > 0.001 {
            return true
        }
        return false
    }

    private func conflictingRuntimeIdentity(
        _ lhs: AgentCmuxRuntimeIdentity?,
        _ rhs: AgentCmuxRuntimeIdentity?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.id != rhs.id
    }

    private func preferredRuntime(
        _ lhs: AgentCmuxRuntimeIdentity?,
        _ rhs: AgentCmuxRuntimeIdentity?
    ) -> AgentCmuxRuntimeIdentity? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        guard lhs.id == rhs.id else { return nil }
        return AgentCmuxRuntimeIdentity(
            id: lhs.id,
            socketPath: mergedRuntimeField(lhs.socketPath, rhs.socketPath),
            bundleIdentifier: mergedRuntimeField(lhs.bundleIdentifier, rhs.bundleIdentifier)
        )
    }

    private func mergedRuntimeField(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return lhs == rhs ? lhs : nil
    }

    private func preferredAuthorityEvidence(
        _ lhs: AgentSessionAuthorityEvidence?,
        _ rhs: AgentSessionAuthorityEvidence?
    ) -> AgentSessionAuthorityEvidence? {
        let candidates = [lhs, rhs].compactMap { $0 }
        return candidates.sorted { first, second in
            if first.isDurableChild != second.isDurableChild { return first.isDurableChild }
            if first == .provisionalAmbiguousChild && second != .provisionalAmbiguousChild { return true }
            if second == .provisionalAmbiguousChild && first != .provisionalAmbiguousChild { return false }
            return first.rawValue < second.rawValue
        }.first
    }

    private func optionalStringPrecedes(_ lhs: String?, _ rhs: String?) -> Bool? {
        if lhs == rhs { return nil }
        guard let lhs else { return false }
        guard let rhs else { return true }
        return lhs < rhs
    }
}
