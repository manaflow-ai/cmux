import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

/// A coding-agent session discovered by observing the process table, with no
/// dependency on hooks firing. Identity (and, for codex, the transcript path)
/// comes from the agent's own argv, environment, or open transcript file, so a
/// session launched through any indirection (a subrouter, a wrapper) is still
/// found.
nonisolated struct ObservedAgentSession: Sendable {
    let sessionID: String
    let agentKind: ChatAgentKind
    let surfaceID: String
    let workspaceID: String?
    let pid: Int
    let workingDirectory: String?
    let transcriptPath: String?
    let sampledAt: Date

    init(
        sessionID: String,
        agentKind: ChatAgentKind,
        surfaceID: String,
        workspaceID: String?,
        pid: Int,
        workingDirectory: String?,
        transcriptPath: String?,
        sampledAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.transcriptPath = transcriptPath
        self.sampledAt = sampledAt
    }
}

extension AgentChatSessionRegistry {
    func stampLifecycleTransition(
        previous: AgentChatSessionRecord?,
        current: inout AgentChatSessionRecord,
        at transitionAt: Date
    ) {
        let wasEnded = previous.map { Self.stateIsEnded($0.state) } ?? false
        let isEnded = Self.stateIsEnded(current.state)
        if isEnded {
            if wasEnded {
                current.endedAt = current.endedAt ?? previous?.endedAt ?? transitionAt
            } else {
                current.endedAt = transitionAt
            }
        } else {
            current.endedAt = nil
        }
    }

    /// Strips an agent-name prefix from prefixed workstream ids
    /// (`claude-<uuid>`); raw hook ids pass through.
    static func normalizedSessionID(_ id: String, source: String) -> String {
        let prefix = "\(source)-"
        if id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }

    nonisolated static func nextState(
        previous: ChatAgentState,
        event: WorkstreamEvent,
        clearsApprovalWait: Bool = false
    ) -> ChatAgentState {
        if stateIsEnded(previous), event.hookEventName != .sessionStart {
            return .ended
        }
        switch event.hookEventName {
        case .sessionStart:
            return .idle
        case .userPromptSubmit, .preToolUse, .postToolUse, .todoWrite:
            if case .working = previous { return previous }
            return .working(since: event.receivedAt)
        case .preCompact, .postCompact:
            // Compaction is lifecycle telemetry. It can occur while a session
            // is idle, so it must not create a synthetic working state.
            return stateAfterLifecycleTelemetry(
                previous: previous,
                clearsApprovalWait: clearsApprovalWait
            )
        case .permissionRequest, .askUserQuestion, .exitPlanMode, .approvalWait, .notification:
            if case .needsInput = previous, !clearsApprovalWait { return previous }
            return .needsInput(since: event.receivedAt)
        case .stop:
            return .idle
        case .subagentStart, .subagentStop:
            // Task subagent lifecycle says nothing about the parent
            // session's activity; keep the current state.
            return stateAfterLifecycleTelemetry(
                previous: previous,
                clearsApprovalWait: clearsApprovalWait
            )
        case .sessionEnd:
            return .ended
        }
    }

    /// Applies one hook event to the state machine while tracking whether a
    /// non-blocking approval wait owns the resulting `.needsInput`. An
    /// approval wait clears as soon as the NEXT event for the same session
    /// arrives (mirroring the Feed's pre-clear semantics) — including
    /// lifecycle telemetry that otherwise preserves the previous state — but
    /// never downgrades a `.needsInput` owned by a blocking decision.
    nonisolated static func hookStateTransition(
        previous: ChatAgentState,
        event: WorkstreamEvent,
        approvalWaitOwnedNeedsInput wasApprovalWait: Bool
    ) -> (state: ChatAgentState, approvalWaitOwnsNeedsInput: Bool) {
        let clearsApprovalWait = wasApprovalWait && event.hookEventName != .approvalWait
        let state = nextState(
            previous: previous,
            event: event,
            clearsApprovalWait: clearsApprovalWait
        )
        let ownsNeedsInput = event.hookEventName == .approvalWait
            && state.needsAttention
            && (wasApprovalWait || !previous.needsAttention)
        return (state: state, approvalWaitOwnsNeedsInput: ownsNeedsInput)
    }

    /// Telemetry events keep the previous state, except that they clear an
    /// approval-wait-owned `.needsInput` back to `.idle`: the agent moved on,
    /// so the wait is over even though no state-bearing hook fired.
    private nonisolated static func stateAfterLifecycleTelemetry(
        previous: ChatAgentState,
        clearsApprovalWait: Bool
    ) -> ChatAgentState {
        if clearsApprovalWait, case .needsInput = previous {
            return .idle
        }
        return previous
    }

    nonisolated static func stateIsEnded(_ state: ChatAgentState) -> Bool {
        if case .ended = state {
            return true
        }
        return false
    }

    #if DEBUG
    /// Compact state label for the debug trace (`idle`/`working`/`needsInput`/
    /// `ended`), stripping any associated value.
    nonisolated static func stateLabel(_ state: ChatAgentState) -> String {
        String(describing: state).split(separator: "(").first.map(String.init) ?? "?"
    }
    #endif
}
