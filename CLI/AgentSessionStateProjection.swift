import Foundation

/// Derives display and automation state from orthogonal stored observations.
struct AgentSessionStateProjection: Sendable, Equatable {
    var process: AgentProcessState
    var session: AgentSessionLifecycleState
    var foreground: AgentForegroundState
    var attention: AgentAttentionState
    var workloads: [AgentWorkloadRecord]
    var activity: AgentActivitySnapshot
    var effective: AgentEffectiveState

    init(
        record: ClaudeHookSessionRecord,
        run: AgentSessionRunRecord,
        probedProcessState: AgentProcessState? = nil
    ) {
        let ended = run.endedAt != nil || record.completedAt != nil
        process = ended
            ? .exited
            : (probedProcessState ?? AgentHookSessionLineageResolver().processState(
                pid: run.pid,
                expectedStartedAt: run.processStartedAt
            ))
        session = ended ? .ended : (record.sessionState ?? .active)
        foreground = ended
            ? .completed
            : (record.foregroundState ?? Self.foreground(from: record.runtimeStatus))
        attention = ended
            ? .none
            : (record.attentionState ?? Self.attention(from: record.runtimeStatus))
        workloads = ended ? [] : (record.workloads ?? [])
        activity = Self.activity(foreground: foreground, workloads: workloads)
        effective = Self.effective(
            process: process,
            session: session,
            foreground: foreground,
            attention: attention,
            activity: activity
        )
    }

    private static func foreground(from status: AgentHookRuntimeStatus?) -> AgentForegroundState {
        switch status {
        case .running?: .working
        case .idle?, .needsInput?: .completed
        case .error?: .failed
        case nil: .unknown
        }
    }

    private static func attention(from status: AgentHookRuntimeStatus?) -> AgentAttentionState {
        switch status {
        case .needsInput?: .needsInput
        case .error?: .error
        case .running?, .idle?: .none
        case nil: .unknown
        }
    }

    private static func activity(
        foreground: AgentForegroundState,
        workloads: [AgentWorkloadRecord]
    ) -> AgentActivitySnapshot {
        var counts = AgentActivitySnapshot.Counts()
        if foreground == .working { counts.foreground = 1 }
        for workload in workloads where workload.keepsSessionBusy && workload.phase.isActive {
            switch workload.kind {
            case .foreground: counts.foreground += 1
            case .backgroundTerminal: counts.backgroundTerminal += 1
            case .monitor: counts.monitor += 1
            case .scheduled: counts.scheduled += 1
            case .subagent: counts.subagent += 1
            case .tool: counts.tool += 1
            case .other: counts.other += 1
            }
        }
        var modes: [AgentActivityMode] = []
        if counts.foreground > 0 { modes.append(.foreground) }
        if counts.backgroundTerminal + counts.other > 0 { modes.append(.background) }
        if counts.monitor > 0 { modes.append(.monitoring) }
        if counts.scheduled > 0 { modes.append(.scheduled) }
        if counts.subagent > 0 { modes.append(.subagents) }
        if counts.tool > 0 { modes.append(.tools) }
        let state: AgentActivityState = if counts.total > 0 {
            .busy
        } else if foreground != .unknown || !workloads.isEmpty {
            .idle
        } else {
            .unknown
        }
        return AgentActivitySnapshot(
            state: state,
            busy: counts.total > 0,
            modes: modes,
            counts: counts
        )
    }

    private static func effective(
        process: AgentProcessState,
        session: AgentSessionLifecycleState,
        foreground: AgentForegroundState,
        attention: AgentAttentionState,
        activity: AgentActivitySnapshot
    ) -> AgentEffectiveState {
        switch session {
        case .ended: return .ended
        case .hibernated: return .hibernated
        case .restoring: return .restoring
        case .active: break
        }
        if process == .exited { return .ended }
        if attention == .needsInput { return .needsInput }
        if attention == .error || foreground == .failed { return .error }
        if activity.counts.foreground > 0
            || activity.counts.backgroundTerminal > 0
            || activity.counts.subagent > 0
            || activity.counts.tool > 0
            || activity.counts.other > 0 {
            return .working
        }
        if activity.counts.monitor > 0 { return .monitoring }
        if activity.counts.scheduled > 0 { return .scheduled }
        if foreground == .interrupted { return .interrupted }
        if foreground == .unknown && attention == .unknown { return .unknown }
        return .idle
    }
}
