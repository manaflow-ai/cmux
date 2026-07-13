import Foundation

extension ClaudeHookSessionStore {
    func completeSessionRecord(_ record: ClaudeHookSessionRecord) -> ClaudeHookSessionRecord {
        var completed = record
        let now = Date().timeIntervalSince1970
        completed.completedAt = now
        completed.sessionState = .ended
        completed.restoreAuthority = false
        completed.runtimeStatus = .idle
        completed.agentLifecycle = .idle
        completed.foregroundState = completed.foregroundState == .interrupted ? .interrupted : .completed
        completed.attentionState = AgentAttentionState.none
        completed.workloads = AgentSessionWorkloadReconciler().cancellingActiveWorkloads(
            completed.workloads ?? [],
            reason: "root_exited",
            now: now
        )
        completed.updatedAt = now
        if let activeRunId = completed.activeRunId,
           let index = completed.runs?.firstIndex(where: { $0.runId == activeRunId }) {
            completed.runs?[index].endedAt = now
            completed.runs?[index].updatedAt = now
            completed.runs?[index].restoreAuthority = false
        }
        completed.activeRunId = nil
        return completed
    }
}
