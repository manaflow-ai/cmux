import Foundation

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
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    var endedAt: TimeInterval?
}

struct AgentSessionRunReconciler: Sendable {
    var maximumRecords: Int

    func reconciling(
        _ existing: [AgentSessionRunRecord],
        activeRunId: String?,
        lineage: AgentHookSessionLineage,
        now: TimeInterval
    ) -> [AgentSessionRunRecord] {
        var runs = existing
        if let activeRunId,
           activeRunId != lineage.runId,
           let index = runs.firstIndex(where: { $0.runId == activeRunId && $0.endedAt == nil }) {
            runs[index].endedAt = now
            runs[index].updatedAt = now
        }
        if let index = runs.firstIndex(where: { $0.runId == lineage.runId }) {
            reconcileExisting(&runs[index], lineage: lineage, now: now)
        } else {
            runs.append(Self.newRun(lineage: lineage, now: now))
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
        let replacesProcessGeneration = run.processStartedAt.flatMap { previousStartedAt in
            lineage.processStartedAt.map { abs(previousStartedAt - $0) > 0.001 }
        } == true
        if replacesProcessGeneration {
            let previous = run
            run = Self.newRun(lineage: lineage, now: now)
            // A stable logical run can span multiple process generations. Once
            // process ancestry proves it is a child, loss of that transient
            // evidence after the parent exits must not turn it into a root.
            run.parentRunId = lineage.parentRunId ?? previous.parentRunId
            run.parentSessionId = lineage.parentSessionId ?? previous.parentSessionId
            if previous.relationship == .spawned {
                run.relationship = .spawned
            }
            run.restoreAuthority = previous.restoreAuthority && lineage.restoreAuthority
            return
        }
        run.pid = lineage.pid ?? run.pid
        run.processStartedAt = lineage.processStartedAt ?? run.processStartedAt
        run.cmuxRuntime = run.cmuxRuntime ?? lineage.cmuxRuntime
        run.parentRunId = lineage.parentRunId ?? run.parentRunId
        run.parentSessionId = lineage.parentSessionId ?? run.parentSessionId
        run.relationship = lineage.relationship == .spawned ? .spawned : (run.relationship ?? lineage.relationship)
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
            startedAt: now,
            updatedAt: now,
            endedAt: nil
        )
    }
}
