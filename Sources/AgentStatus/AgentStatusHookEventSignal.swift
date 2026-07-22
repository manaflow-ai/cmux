import CMUXAgentLaunch
import Darwin
import Foundation

/// Status meaning and runtime-generation binding extracted from a hook event.
struct AgentStatusHookEventSignal: Equatable, Sendable {
    private static let statusSignalField = "_cmux_agent_status_signal"

    let statusKey: String
    let lifecycle: AgentHibernationLifecycleState
    let observedAt: Date
    let runtimePIDKey: String
    let runtimePID: Int
    let runtimeSessionID: String

    init?(event: WorkstreamEvent) {
        guard let lifecycle = Self.explicitLifecycle(from: event.extraFieldsJSON),
              let runtime = Self.runtimeBinding(event: event) else {
            return nil
        }
        self.statusKey = runtime.statusKey
        self.lifecycle = lifecycle
        self.observedAt = event.receivedAt
        self.runtimePIDKey = runtime.pidKey
        self.runtimePID = runtime.pid
        self.runtimeSessionID = runtime.sessionID
    }

    static func runtimeBinding(
        event: WorkstreamEvent
    ) -> (statusKey: String, pidKey: String, pid: Int, sessionID: String)? {
        let source = event.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let statusKey = FeedCoordinator.lifecycleStatusKey(forSource: source)
        guard AgentHibernationLifecycleStatusKeys.isAllowed(statusKey),
              let pid = event.ppid,
              pid > 0,
              pid_t(exactly: pid) != nil,
              let sessionID = Self.sessionID(from: event.sessionId, source: source) else {
            return nil
        }
        let pidKey = statusKey == "claude_code" ? statusKey : "\(statusKey).\(sessionID)"
        return (statusKey, pidKey, pid, sessionID)
    }

    private static func sessionID(from workstreamID: String, source: String) -> String? {
        let normalized = workstreamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(source)-"
        guard normalized.count > prefix.count,
              normalized.prefix(prefix.count).lowercased() == prefix else {
            return nil
        }
        return String(normalized.dropFirst(prefix.count))
    }

    private static func explicitLifecycle(
        from extraFieldsJSON: String?
    ) -> AgentHibernationLifecycleState? {
        guard let extraFieldsJSON,
              let data = extraFieldsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawValue = object[statusSignalField] as? String else {
            return nil
        }
        return AgentHibernationLifecycleState.parseCLIValue(rawValue)
    }
}
