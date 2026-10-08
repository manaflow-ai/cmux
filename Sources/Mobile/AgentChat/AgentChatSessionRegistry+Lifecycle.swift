import CMUXAgentLaunch
import CmuxAgentChat
import CmuxFoundation
import CmuxMobileHost
import Foundation

/// A coding-agent session discovered by observing the process table, with no
/// dependency on hooks firing. Identity (and, for codex, the transcript path)
/// comes from the agent's own argv, environment, or open transcript file, so a
/// session launched through any indirection (a subrouter, a wrapper) is still
/// found.
struct ObservedAgentSession: Sendable {
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
        // Feed ingress uses a lossless v1 envelope so agent/session boundaries
        // cannot be confused by hyphens. Decode it before the chat registry
        // indexes records or consults the agent-owned hook store.
        if let identifier = FeedWorkstreamIdentifier(rawValue: id),
           identifier.agentID == source {
            return identifier.sessionID
        }
        let prefix = "\(source)-"
        if id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }

    nonisolated static func nextState(
        previous: ChatAgentState,
        event: WorkstreamEvent
    ) -> ChatAgentState {
        if stateIsEnded(previous), event.hookEventName != .sessionStart {
            return .ended
        }
        // Claude emits AskUserQuestion and ExitPlanMode through PreToolUse.
        // Feed telemetry for that hook arrives before the dedicated journal
        // event, so treating every PreToolUse as working briefly overwrites
        // the blocking state and leaves the sidebar waiting for Claude's
        // delayed idle notification. Preserve the needs-input state at the
        // first hook hop; PermissionRequest/Notification still converge on
        // the same state in permission modes that emit them.
        if event.source == "claude",
           event.hookEventName == .preToolUse,
           let toolName = event.toolName,
           toolName == "AskUserQuestion" || toolName == "ExitPlanMode" {
            return .needsInput(since: event.receivedAt)
        }
        switch event.hookEventName {
        case .sessionStart:
            return .idle
        case .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure, .todoWrite:
            if case .working = previous { return previous }
            return .working(since: event.receivedAt)
        case .preCompact, .postCompact:
            // Compaction is lifecycle telemetry. It can occur while a session
            // is idle, so it must not create a synthetic working state.
            return previous
        case .permissionRequest, .askUserQuestion, .exitPlanMode, .notification:
            // Claude and Grok can deliver their idle reminder asynchronously
            // after the Stop hook. Once Stop has settled the session, that
            // reminder is informational and must not reopen Needs input. The
            // ended-session guard above handles the stronger SessionEnd
            // boundary; this preserves the idle state between the two hooks.
            if event.hookEventName == .notification,
               isIdleReminderNotification(event),
               case .idle = previous {
                return previous
            }
            if case .needsInput = previous { return previous }
            return .needsInput(since: event.receivedAt)
        case .stop:
            return .idle
        case .subagentStart, .subagentStop:
            // Subagent lifecycle says nothing about the parent
            // session's activity; keep the current state.
            return previous
        case .sessionEnd:
            return .ended
        }
    }

    nonisolated static func stateIsEnded(_ state: ChatAgentState) -> Bool {
        if case .ended = state {
            return true
        }
        return false
    }

    private nonisolated static func isIdleReminderNotification(_ event: WorkstreamEvent) -> Bool {
        guard event.hookEventName == .notification,
              let data = event.extraFieldsJSON?.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return ["notification_type", "reason"].contains { key in
            guard let value = fields[key] as? String else { return false }
            return value.caseInsensitiveCompare("idle_prompt") == .orderedSame
        }
    }
}
