public import Foundation

/// Projects restore ownership from one logical session's canonical process run.
///
/// Compatibility fields on the logical record can lag run history during a
/// fork, resume, or concurrent registry write. Every restore consumer uses this
/// projector so stale record-level authority cannot promote a child or demote a
/// new root. The ordering and duplicate merge intentionally match the CLI's
/// `AgentSessionRunCanonicalizer`.
public struct CmuxAgentSessionRunAuthorityProjection: Sendable {
    public struct Runtime: Codable, Equatable, Sendable {
        public var id: String
        public var socketPath: String?
        public var bundleIdentifier: String?

        public init(id: String, socketPath: String? = nil, bundleIdentifier: String? = nil) {
            self.id = id
            self.socketPath = socketPath
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public enum Relationship: String, Codable, Sendable {
        case spawned
        case forked
        case resumed
    }

    public enum AuthorityEvidence: String, Codable, Equatable, Sendable {
        case verifiedForkRoot = "verified_fork_root"
        case managedChild = "managed_child"
        case explicitSpawnedChild = "explicit_spawned_child"
        case verifiedAncestorChild = "verified_ancestor_child"
        case provisionalAmbiguousChild = "provisional_ambiguous_child"
        case legacyChild = "legacy_child"

        fileprivate var isDurableChild: Bool {
            switch self {
            case .managedChild, .explicitSpawnedChild, .verifiedAncestorChild, .legacyChild:
                true
            case .verifiedForkRoot, .provisionalAmbiguousChild:
                false
            }
        }
    }

    public struct Run: Codable, Equatable, Sendable {
        public var runId: String
        public var pid: Int?
        public var processStartedAt: TimeInterval?
        public var cmuxRuntime: Runtime?
        public var parentRunId: String?
        public var parentSessionId: String?
        public var relationship: Relationship?
        public var restoreAuthority: Bool
        public var authorityEvidence: AuthorityEvidence?
        public var cmuxHibernationResumeAttemptId: String?
        public var startedAt: TimeInterval
        public var updatedAt: TimeInterval
        public var endedAt: TimeInterval?
        public var identityConflict: Bool?

        public init(
            runId: String,
            pid: Int? = nil,
            processStartedAt: TimeInterval? = nil,
            cmuxRuntime: Runtime? = nil,
            parentRunId: String? = nil,
            parentSessionId: String? = nil,
            relationship: Relationship? = nil,
            restoreAuthority: Bool,
            authorityEvidence: AuthorityEvidence? = nil,
            cmuxHibernationResumeAttemptId: String? = nil,
            startedAt: TimeInterval,
            updatedAt: TimeInterval,
            endedAt: TimeInterval? = nil,
            identityConflict: Bool? = nil
        ) {
            self.runId = runId
            self.pid = pid
            self.processStartedAt = processStartedAt
            self.cmuxRuntime = cmuxRuntime
            self.parentRunId = parentRunId
            self.parentSessionId = parentSessionId
            self.relationship = relationship
            self.restoreAuthority = restoreAuthority
            self.authorityEvidence = authorityEvidence
            self.cmuxHibernationResumeAttemptId = cmuxHibernationResumeAttemptId
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.endedAt = endedAt
            self.identityConflict = identityConflict
        }
    }

    private struct RecordEnvelope: Decodable {
        var restoreAuthority: Bool?
        var runs: [Run]?
        var activeRunId: String?
    }

    public init() {}

    /// Returns `nil` when a nonempty run projection cannot be decoded safely.
    /// Callers must treat `nil` as non-authoritative.
    public func projectedRestoreAuthority(recordJSON: Data) -> Bool? {
        guard let record = try? JSONDecoder().decode(RecordEnvelope.self, from: recordJSON) else {
            return nil
        }
        return projectedRestoreAuthority(
            recordRestoreAuthority: record.restoreAuthority,
            runs: record.runs,
            activeRunId: record.activeRunId
        )
    }

    /// Empty or absent run history preserves the legacy record-level behavior.
    /// Once a nonempty run array exists, it is authoritative.
    public func projectedRestoreAuthority(
        recordRestoreAuthority: Bool?,
        runs: [Run]?,
        activeRunId: String?
    ) -> Bool {
        guard let runs, !runs.isEmpty else {
            return recordRestoreAuthority != false
        }
        return projectedRun(runs: runs, activeRunId: activeRunId)?.restoreAuthority ?? false
    }

    public func projectedRun(runs: [Run], activeRunId: String?) -> Run? {
        guard !runs.isEmpty else { return nil }
        let canonicalRuns = canonicalRuns(runs)
        if let activeRunId,
           let active = canonicalRuns.first(where: { $0.runId == activeRunId }) {
            return active
        }
        return canonicalRuns.dropFirst().reduce(canonicalRuns[0]) { newest, candidate in
            isNewer(candidate, than: newest) ? candidate : newest
        }
    }

    private func canonicalRuns(_ runs: [Run]) -> [Run] {
        var newestByRunID: [String: Run] = [:]
        newestByRunID.reserveCapacity(runs.count)
        for run in runs {
            if let current = newestByRunID[run.runId] {
                newestByRunID[run.runId] = canonicalDuplicate(run, current)
            } else {
                newestByRunID[run.runId] = run
            }
        }
        return newestByRunID.values.sorted { $0.runId < $1.runId }
    }

    private func isNewer(_ candidate: Run, than current: Run) -> Bool {
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
        if let result = optionalStringPrecedes(
            candidate.cmuxHibernationResumeAttemptId,
            current.cmuxHibernationResumeAttemptId
        ) {
            return result
        }
        if candidate.restoreAuthority != current.restoreAuthority { return !candidate.restoreAuthority }
        return false
    }

    private func canonicalDuplicate(_ candidate: Run, _ current: Run) -> Run {
        guard candidate.updatedAt == current.updatedAt,
              candidate.startedAt == current.startedAt else {
            return isNewer(candidate, than: current) ? candidate : current
        }

        let preferred = isNewer(candidate, than: current) ? candidate : current
        let alternate = preferred == candidate ? current : candidate
        var merged = preferred
        let processIdentityConflict = conflictingProcessIdentity(candidate, current)
        let runtimeIdentityConflict = conflictingRuntimeIdentity(candidate.cmuxRuntime, current.cmuxRuntime)
        let resumeProofConflict = if let candidateAttempt = candidate.cmuxHibernationResumeAttemptId,
                                     let currentAttempt = current.cmuxHibernationResumeAttemptId {
            candidateAttempt != currentAttempt
        } else {
            false
        }
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
        if resumeProofConflict {
            merged.cmuxHibernationResumeAttemptId = nil
            merged.restoreAuthority = false
        } else {
            merged.cmuxHibernationResumeAttemptId = candidate.cmuxHibernationResumeAttemptId
                ?? current.cmuxHibernationResumeAttemptId
        }
        if let candidateEndedAt = candidate.endedAt, let currentEndedAt = current.endedAt {
            merged.endedAt = max(candidateEndedAt, currentEndedAt)
        } else {
            merged.endedAt = candidate.endedAt ?? current.endedAt
        }
        if merged.endedAt != nil { merged.restoreAuthority = false }
        return merged
    }

    private func conflictingProcessIdentity(_ lhs: Run, _ rhs: Run) -> Bool {
        if let lhsPID = lhs.pid, let rhsPID = rhs.pid, lhsPID != rhsPID { return true }
        if let lhsStartedAt = lhs.processStartedAt,
           let rhsStartedAt = rhs.processStartedAt,
           abs(lhsStartedAt - rhsStartedAt) > 0.001 {
            return true
        }
        return false
    }

    private func conflictingRuntimeIdentity(_ lhs: Runtime?, _ rhs: Runtime?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.id != rhs.id
    }

    private func preferredRuntime(_ lhs: Runtime?, _ rhs: Runtime?) -> Runtime? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        guard lhs.id == rhs.id else { return nil }
        return Runtime(
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
        _ lhs: AuthorityEvidence?,
        _ rhs: AuthorityEvidence?
    ) -> AuthorityEvidence? {
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
