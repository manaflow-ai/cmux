import Foundation

/// Stores nested Claude sessions without promoting them to the surface's active
/// restore slot or mutating parent UI state.
struct ClaudeChildSessionObserver: Sendable {
    func recordPrompt(
        input: ClaudeHookParsedInput,
        store: ClaudeHookSessionStore,
        workspaceId: String,
        surfaceId: String,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?,
        environment: [String: String]
    ) {
        guard let sessionId = input.sessionId,
              shouldRecord(sessionId: sessionId, store: store, pid: pid, environment: environment) else {
            return
        }
        _ = try? store.upsert(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: input.cwd,
            transcriptPath: input.transcriptPath,
            pid: pid,
            launchCommand: launchCommand,
            isRestorable: false,
            agentLifecycle: .running,
            runtimeStatus: .running,
            updateRuntimeStatus: true
        )
        _ = try? store.reconcileSemanticState(
            sessionId: sessionId,
            foregroundState: .working,
            attentionState: AgentAttentionState.none
        )
    }

    func recordStop(
        input: ClaudeHookParsedInput,
        store: ClaudeHookSessionStore,
        workspaceId: String,
        surfaceId: String,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?,
        environment: [String: String]
    ) {
        guard let sessionId = input.sessionId,
              shouldRecord(sessionId: sessionId, store: store, pid: pid, environment: environment) else {
            return
        }
        let workloads = ClaudeAgentWorkloadAdapter().workloads(from: input, now: Date().timeIntervalSince1970)
        let busy = workloads?.contains { $0.keepsSessionBusy && $0.phase.isActive } == true
        _ = try? store.upsert(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: input.cwd,
            transcriptPath: input.transcriptPath,
            pid: pid,
            launchCommand: launchCommand,
            isRestorable: false,
            agentLifecycle: busy ? .running : .idle,
            runtimeStatus: busy ? .running : .idle,
            updateRuntimeStatus: true
        )
        _ = try? store.reconcileSemanticState(
            sessionId: sessionId,
            foregroundState: AgentStopStateAdapter().isInterrupted(
                provider: "claude",
                input: input,
                transcriptPath: input.transcriptPath
            ) ? .interrupted : .completed,
            attentionState: AgentAttentionState.none,
            workloads: workloads
        )
    }

    private func shouldRecord(
        sessionId: String,
        store: ClaudeHookSessionStore,
        pid: Int?,
        environment: [String: String]
    ) -> Bool {
        guard !AgentHookSessionLineageResolver().resolve(
            agentName: "claude",
            sessionId: sessionId,
            pid: pid,
            environment: environment
        ).restoreAuthority else { return false }
        return (try? store.projectedRestoreAuthority(sessionId: sessionId)) != true
    }
}
