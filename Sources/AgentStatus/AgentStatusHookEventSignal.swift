import CMUXAgentLaunch
import Darwin
import Foundation

/// Status meaning and runtime-generation binding extracted from a hook event.
struct AgentStatusHookEventSignal: Equatable, Sendable {
    private static let statusSignalField = "_cmux_agent_status_signal"
    private static let statusRevisionField = "_cmux_agent_status_revision"
    private static let pidNamespaceField = "_cmux_agent_pid_namespace"

    let statusKey: String
    let lifecycle: AgentHibernationLifecycleState
    let observedAt: Date
    let runtimePIDKey: String
    let runtimePID: Int
    let runtimePIDNamespace: AgentStatusPIDNamespace
    let runtimeSessionID: String
    let revision: UInt64?

    init?(event: WorkstreamEvent) {
        guard let payload = Self.explicitPayload(from: event.extraFieldsJSON),
              let runtime = Self.runtimeBinding(event: event) else {
            return nil
        }
        self.statusKey = runtime.statusKey
        self.lifecycle = payload.lifecycle
        self.observedAt = event.receivedAt
        self.runtimePIDKey = runtime.pidKey
        self.runtimePID = runtime.pid
        self.runtimePIDNamespace = runtime.pidNamespace
        self.runtimeSessionID = runtime.sessionID
        self.revision = payload.revision
    }

    static func runtimeBinding(
        event: WorkstreamEvent
    ) -> (
        statusKey: String,
        pidKey: String,
        pid: Int,
        pidNamespace: AgentStatusPIDNamespace,
        sessionID: String
    )? {
        let source = event.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let statusKey = FeedCoordinator.lifecycleStatusKey(forSource: source)
        guard AgentHibernationLifecycleStatusKeys.isAllowed(statusKey),
              let pid = event.ppid,
              pid > 0,
              pid_t(exactly: pid) != nil,
              let pidNamespace = Self.pidNamespace(from: event.extraFieldsJSON),
              let sessionID = Self.sessionID(from: event.sessionId, source: source) else {
            return nil
        }
        let pidKey = "\(statusKey).\(sessionID)"
        return (statusKey, pidKey, pid, pidNamespace, sessionID)
    }

    private static func pidNamespace(from extraFieldsJSON: String?) -> AgentStatusPIDNamespace? {
        guard let extraFieldsJSON else { return .local }
        guard let data = extraFieldsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let rawValue = object[pidNamespaceField] else { return .local }
        guard let stringValue = rawValue as? String else { return nil }
        return AgentStatusPIDNamespace(rawValue: stringValue)
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

    private static func explicitPayload(
        from extraFieldsJSON: String?
    ) -> (lifecycle: AgentHibernationLifecycleState, revision: UInt64?)? {
        guard let extraFieldsJSON,
              let data = extraFieldsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawValue = object[statusSignalField] as? String,
              let lifecycle = AgentHibernationLifecycleState.parseCLIValue(rawValue) else {
            return nil
        }
        let revision: UInt64?
        if let number = object[statusRevisionField] as? NSNumber {
            revision = number.uint64Value
        } else if let rawRevision = object[statusRevisionField] as? String {
            revision = UInt64(rawRevision)
        } else {
            revision = nil
        }
        return (lifecycle, revision)
    }
}
