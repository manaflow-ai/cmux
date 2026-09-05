import CmuxAgentJournal
import Foundation

extension CMUXCLI {
    /// Converts adapter evidence and existing localized presentation into one journal candidate.
    /// Lifecycle reconciliation, receipts, policy, and effect delivery are owned by the app.
    func semanticNotificationCommand(
        source: String, agentKey: String, sessionId: String?,
        workspaceId: String, surfaceId: String, kind: AgentJournalEventKind,
        rawObject: [String: Any]?, payload: String, pendingWork: Bool = false
    ) throws -> String {
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3 else { throw CLIError(message: String(localized: "cli.notification.invalidPayload", defaultValue: "Invalid notification payload")) }
        let meta = fields.count > 3 ? fields[3].split(separator: ";").map(String.init) : []
        let category = meta.first { $0.hasPrefix("c=") }.map { String($0.dropFirst(2)) }
            ?? (kind == .turnCompleted ? "turn-complete" : "other")
        let notification = AgentJournalNotification(title: fields[0], subtitle: fields[1], body: fields[2],
            category: category, correlationKey: meta.first { $0.hasPrefix("k=") }.map { String($0.dropFirst(2)) })
        return try semanticNotificationCommand(source: source, agentKey: agentKey, sessionId: sessionId,
            workspaceId: workspaceId, surfaceId: surfaceId, kind: kind, rawObject: rawObject,
            notification: notification, pendingWork: pendingWork || meta.contains("p=1"), isSubagent: meta.contains("n=1"))
    }

    func semanticNotificationCommand(
        source: String, agentKey: String, sessionId: String?, workspaceId: String, surfaceId: String,
        kind: AgentJournalEventKind, rawObject: [String: Any]?, notification: AgentJournalNotification,
        pendingWork: Bool = false, isSubagent: Bool = false
    ) throws -> String {
        var context = Self.semanticAttentionContext(rawObject)
        var notification = notification
        switch kind {
        case .errorReported, .messagePublished: notification.category = "other"
        case .turnCompleted: notification.category = "turn-complete"
        case .idleObserved: notification.category = "idle-reminder"
        case .approvalRequested, .planReviewRequested: notification.category = "needs-permission"
        default: break
        }
        context.notification = notification
        if context.requestIdentity == nil { context.requestIdentity = notification.correlationKey }
        let draft = AgentJournalEventDraft(kind: kind,
            occurredAtMs: Self.semanticOccurredAtMs(rawObject) ?? Int64(Date().timeIntervalSince1970 * 1000),
            source: source, agentKey: agentKey, sessionId: sessionId,
            workspaceId: workspaceId, surfaceId: surfaceId,
            isSubagent: isSubagent, pendingWork: pendingWork,
            nativeEvent: rawObject?["hook_event_name"] as? String, attention: context)
        let data = try JSONEncoder().encode(draft)
        return "agent_journal_append \(String(decoding: data, as: UTF8.self))"
    }

    static func semanticAttentionContext(_ object: [String: Any]?) -> AgentAttentionContext {
        func identifier(_ keys: [String]) -> String? {
            for key in keys {
                if let value = object?[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        // Identical prompts and responses can be different real turns. Only
        // native IDs identify replays; identity-less hooks use lifecycle generations.
        return AgentAttentionContext(
            eventIdentity: identifier(["event_id", "eventId", "message_id", "uuid"]),
            turnIdentity: identifier(["turn_id", "turnId"]),
            requestIdentity: identifier(["tool_use_id", "toolUseId", "toolUseID", "tool_call_id", "toolCallId", "request_id", "requestId"]))
    }

    static func semanticOccurredAtMs(_ object: [String: Any]?) -> Int64? {
        for key in ["occurred_at_ms", "timestamp_ms"] {
            if let value = object?[key] as? NSNumber, value.int64Value >= 0 { return value.int64Value }
        }
        return nil
    }
}
