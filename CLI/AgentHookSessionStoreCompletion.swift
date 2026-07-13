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
        if var runs = completed.runs {
            for index in runs.indices where runs[index].endedAt == nil {
                runs[index].endedAt = now
                runs[index].updatedAt = now
                runs[index].restoreAuthority = false
            }
            completed.runs = runs
        }
        completed.activeRunId = nil
        return completed
    }
}
