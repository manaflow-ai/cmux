import CMUXAgentLaunch
import CoreFoundation
import Darwin
import Foundation

/// Status meaning and runtime-generation binding extracted from a hook event.
struct AgentStatusHookEventSignal: Equatable, Sendable {
    private enum RuntimeGeneration {
        case absent
        case exact(seconds: Int64, microseconds: Int64)
    }

    private static let statusSignalField = "_cmux_agent_status_signal"
    private static let statusRevisionField = "_cmux_agent_status_revision"
    private static let pidStartSecondsField = "_cmux_agent_pid_start_seconds"
    private static let pidStartMicrosecondsField = "_cmux_agent_pid_start_microseconds"

    let statusKey: String
    let lifecycle: AgentHibernationLifecycleState
    let observedAt: Date
    let runtimePIDKey: String
    let runtimeProcessIdentity: AgentPIDProcessIdentity?
    let runtimePID: Int
    let runtimePIDNamespace: AgentStatusPIDNamespace
    let runtimeSessionID: String
    let revision: UInt64?

    init?(event: WorkstreamEvent) {
        guard let payload = Self.explicitPayload(from: event.extraFieldsJSON),
              let generation = Self.runtimeGeneration(from: event.extraFieldsJSON),
              let runtime = Self.runtimeBinding(event: event) else {
            return nil
        }
        self.statusKey = runtime.statusKey
        self.lifecycle = payload.lifecycle
        self.observedAt = event.receivedAt
        self.runtimePIDKey = runtime.pidKey
        switch generation {
        case .absent:
            self.runtimeProcessIdentity = nil
        case .exact(let seconds, let microseconds):
            self.runtimeProcessIdentity = AgentPIDProcessIdentity(
                pid: pid_t(runtime.pid),
                startSeconds: seconds,
                startMicroseconds: microseconds
            )
        }
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
              let pidNamespace = Self.pidNamespace(event: event),
              let sessionID = Self.sessionID(from: event.sessionId, source: source) else {
            return nil
        }
        let pidKey = "\(statusKey).\(sessionID)"
        return (statusKey, pidKey, pid, pidNamespace, sessionID)
    }

    static func pidNamespace(event: WorkstreamEvent) -> AgentStatusPIDNamespace? {
        switch event.processNamespace {
        case .local: return .local
        case .remote: return .remote
        case .unknown: return nil
        }
    }

    /// Returns true only when a legacy payload is proven not to contain the
    /// structured status field. Malformed payloads fail closed.
    static func statusSignalFieldIsAbsent(from extraFieldsJSON: String?) -> Bool {
        guard let extraFieldsJSON else { return true }
        guard let data = extraFieldsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object[statusSignalField] == nil
    }

    /// Parses an optional exact process generation. A partial or malformed
    /// generation rejects the status signal instead of weakening its ordering.
    private static func runtimeGeneration(
        from extraFieldsJSON: String?
    ) -> RuntimeGeneration? {
        guard let extraFieldsJSON else { return .absent }
        guard let data = extraFieldsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawSeconds = object[pidStartSecondsField]
        let rawMicroseconds = object[pidStartMicrosecondsField]
        guard rawSeconds != nil || rawMicroseconds != nil else { return .absent }
        guard let rawSeconds,
              let rawMicroseconds,
              let secondsValue = exactUInt64(from: rawSeconds),
              let microsecondsValue = exactUInt64(from: rawMicroseconds),
              let seconds = Int64(exactly: secondsValue),
              let microseconds = Int64(exactly: microsecondsValue),
              (0..<1_000_000).contains(microseconds) else {
            return nil
        }
        return .exact(seconds: seconds, microseconds: microseconds)
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
        var revision: UInt64?
        if let rawRevision = object[statusRevisionField] {
            guard let parsedRevision = exactUInt64(from: rawRevision) else { return nil }
            revision = parsedRevision
        }
        return (lifecycle, revision)
    }

    private static func exactUInt64(from value: Any) -> UInt64? {
        if let string = value as? String {
            return UInt64(string)
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return UInt64(number.stringValue)
    }
}
