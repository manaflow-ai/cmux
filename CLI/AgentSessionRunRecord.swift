import Foundation

struct AgentStableProcessIdentity: Sendable, Equatable {
    let executablePath: String?
    let arguments: [String]
    let startTime: TimeInterval
}

struct AgentStableProcessIdentityValidator: Sendable {
    func identity(
        for pid: Int,
        probedKernelStartTime: TimeInterval,
        processStartTimeLookup: (Int) -> TimeInterval?,
        executablePathLookup: (Int) -> String?,
        argumentsLookup: (Int) -> [String]?
    ) -> AgentStableProcessIdentity? {
        let executablePath = executablePathLookup(pid)
        let arguments = argumentsLookup(pid) ?? []
        guard let verifiedKernelStartTime = processStartTimeLookup(pid),
              abs(verifiedKernelStartTime - probedKernelStartTime) <= 0.001 else {
            return nil
        }
        return AgentStableProcessIdentity(
            executablePath: executablePath,
            arguments: arguments,
            startTime: verifiedKernelStartTime
        )
    }
}

/// One process generation of a logical agent session.
struct AgentSessionRunRecord: Codable, Sendable, Equatable {
    var runId: String
    var pid: Int?
    var processStartedAt: TimeInterval?
    var cmuxRuntime: AgentCmuxRuntimeIdentity? = nil
    var parentRunId: String?
    var parentSessionId: String?
    var relationship: AgentSessionRelationship?
    var restoreAuthority: Bool
    var authorityEvidence: AgentSessionAuthorityEvidence? = nil
    /// Exact app-issued proof for an unknown custom CLI generation resumed by
    /// cmux. Optional so older readers ignore it and older rows fail closed.
    var cmuxHibernationResumeAttemptId: String? = nil
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    var endedAt: TimeInterval?
    /// Set only when equal-time duplicate rows disagree about the process or
    /// cmux runtime generation. Consumers must not fall back to record-level
    /// identity for a conflicted run.
    var identityConflict: Bool? = nil

    func cmuxRuntime(fallingBackTo recordRuntime: AgentCmuxRuntimeIdentity?) -> AgentCmuxRuntimeIdentity? {
        guard identityConflict != true else { return nil }
        return cmuxRuntime ?? recordRuntime
    }
}

struct AgentSessionRunReconciler: Sendable {
    var maximumRecords: Int
    private let authorityTransition: AgentSessionAuthorityTransition

    init(
        maximumRecords: Int,
        authorityTransition: AgentSessionAuthorityTransition = AgentSessionAuthorityTransition()
    ) {
        self.maximumRecords = maximumRecords
        self.authorityTransition = authorityTransition
    }

    func reconciling(
        _ existing: [AgentSessionRunRecord],
        activeRunId: String?,
        lineage: AgentHookSessionLineage,
        now: TimeInterval
    ) -> [AgentSessionRunRecord] {
        var runs = existing
        var effectiveLineage = lineage
        if let activeRunId,
           activeRunId != lineage.runId,
           let index = runs.firstIndex(where: { $0.runId == activeRunId && $0.endedAt == nil }) {
            runs[index].endedAt = now
            runs[index].updatedAt = now
            runs[index].restoreAuthority = false
            if effectiveLineage.parentRunId == nil {
                effectiveLineage.parentRunId = activeRunId
                if effectiveLineage.relationship == nil {
                    effectiveLineage.relationship = .resumed
                }
            }
        }
        if let index = runs.firstIndex(where: { $0.runId == effectiveLineage.runId }) {
            reconcileExisting(&runs[index], lineage: effectiveLineage, now: now)
        } else {
            runs.append(Self.newRun(lineage: effectiveLineage, now: now))
        }
        guard runs.count > maximumRecords else { return runs }
        let active = runs.filter { $0.endedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }
        if active.count >= maximumRecords { return Array(active.prefix(maximumRecords)) }
        let ended = runs.filter { $0.endedAt != nil }.sorted { $0.updatedAt > $1.updatedAt }
        return active + Array(ended.prefix(maximumRecords - active.count))
    }

    private func reconcileExisting(
        _ run: inout AgentSessionRunRecord,
        lineage: AgentHookSessionLineage,
        now: TimeInterval
    ) {
        let previousEvidence = authorityTransition.persistedEvidence(for: run)
        let recoversProvisionalFork = authorityTransition.canRecoverProvisionalFork(
            previous: previousEvidence,
            incoming: lineage
        )
        let incomingDurableEvidence = lineage.authorityEvidence.flatMap {
            $0.isDurableChild ? $0 : nil
        }
        let replacesProcessGeneration = run.processStartedAt.flatMap { previousStartedAt in
            lineage.processStartedAt.map { abs(previousStartedAt - $0) > 0.001 }
        } == true
        if replacesProcessGeneration {
            let previous = run
            run = Self.newRun(lineage: lineage, now: now)
            if recoversProvisionalFork {
                run.parentRunId = lineage.parentRunId ?? previous.parentRunId
                run.parentSessionId = lineage.parentSessionId ?? previous.parentSessionId
                return
            }
            // A stable logical run can span multiple process generations. Once
            // durable evidence proves it is a child, loss of process ancestry
            // after the parent exits must not turn it into a root.
            run.parentRunId = lineage.parentRunId ?? previous.parentRunId
            run.parentSessionId = lineage.parentSessionId ?? previous.parentSessionId
            if let previousEvidence, previousEvidence.isDurableChild {
                run.relationship = .spawned
                run.restoreAuthority = false
                run.authorityEvidence = previousEvidence
            } else if let incomingDurableEvidence {
                run.relationship = .spawned
                run.restoreAuthority = false
                run.authorityEvidence = incomingDurableEvidence
            } else if previousEvidence == .provisionalAmbiguousChild {
                run.relationship = .spawned
                run.restoreAuthority = false
                run.authorityEvidence = .provisionalAmbiguousChild
            } else {
                // Root authority is generation-scoped. Completion demotes the
                // exited generation, but a verified replacement root starts
                // with the new lineage's authority.
                run.restoreAuthority = lineage.restoreAuthority
            }
            return
        }
        run.pid = lineage.pid ?? run.pid
        run.processStartedAt = lineage.processStartedAt ?? run.processStartedAt
        run.cmuxRuntime = lineage.cmuxRuntime ?? run.cmuxRuntime
        if recoversProvisionalFork {
            run.parentRunId = lineage.parentRunId ?? run.parentRunId
            run.parentSessionId = lineage.parentSessionId ?? run.parentSessionId
            run.relationship = .forked
            run.restoreAuthority = true
            run.authorityEvidence = .verifiedForkRoot
            run.endedAt = nil
            run.updatedAt = now
            return
        }
        run.parentRunId = lineage.parentRunId ?? run.parentRunId
        run.parentSessionId = lineage.parentSessionId ?? run.parentSessionId
        run.cmuxHibernationResumeAttemptId = lineage.hibernationResumeAttemptId?.uuidString
            ?? run.cmuxHibernationResumeAttemptId
        if let previousEvidence, previousEvidence.isDurableChild {
            run.relationship = .spawned
            run.restoreAuthority = false
            run.authorityEvidence = previousEvidence
            run.endedAt = nil
            run.updatedAt = now
            return
        }
        if let incomingDurableEvidence {
            run.relationship = .spawned
            run.restoreAuthority = false
            run.authorityEvidence = incomingDurableEvidence
            run.endedAt = nil
            run.updatedAt = now
            return
        }
        if previousEvidence == .provisionalAmbiguousChild {
            run.relationship = .spawned
            run.restoreAuthority = false
            run.authorityEvidence = .provisionalAmbiguousChild
            run.endedAt = nil
            run.updatedAt = now
            return
        }
        run.relationship = lineage.relationship == .spawned ? .spawned : (run.relationship ?? lineage.relationship)
        run.authorityEvidence = lineage.authorityEvidence ?? run.authorityEvidence
        // Authority is monotonic within one process generation. New child
        // evidence can demote a run, but missing ancestry later cannot promote
        // that child into a restore owner.
        run.restoreAuthority = run.restoreAuthority && lineage.restoreAuthority
        run.endedAt = nil
        run.updatedAt = now
    }

    private static func newRun(
        lineage: AgentHookSessionLineage,
        now: TimeInterval
    ) -> AgentSessionRunRecord {
        AgentSessionRunRecord(
            runId: lineage.runId,
            pid: lineage.pid,
            processStartedAt: lineage.processStartedAt,
            cmuxRuntime: lineage.cmuxRuntime,
            parentRunId: lineage.parentRunId,
            parentSessionId: lineage.parentSessionId,
            relationship: lineage.relationship,
            restoreAuthority: lineage.restoreAuthority,
            authorityEvidence: lineage.authorityEvidence,
            cmuxHibernationResumeAttemptId: lineage.hibernationResumeAttemptId?.uuidString,
            startedAt: now,
            updatedAt: now,
            endedAt: nil
        )
    }
}
