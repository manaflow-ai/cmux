import CmuxAgentJournal
import CryptoKit
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
        var context = Self.semanticAttentionContext(rawObject)
        context.notification = AgentJournalNotification(title: fields[0], subtitle: fields[1], body: fields[2],
            category: category, correlationKey: meta.first { $0.hasPrefix("k=") }.map { String($0.dropFirst(2)) })
        if let correlationKey = context.notification?.correlationKey {
            context.requestIdentity = correlationKey
        }
        let draft = AgentJournalEventDraft(kind: kind,
            occurredAtMs: Self.semanticOccurredAtMs(rawObject) ?? Int64(Date().timeIntervalSince1970 * 1000),
            source: source, agentKey: agentKey, sessionId: sessionId,
            workspaceId: workspaceId, surfaceId: surfaceId,
            isSubagent: meta.contains("n=1"), pendingWork: pendingWork || meta.contains("p=1"),
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
        // The fallback is an opaque hash of structured producer evidence, never
        // a prose classifier. Transport routing and receipt time are excluded.
        var evidence = object ?? [:]
        for key in ["workspace_id", "surface_id", "_received_at", "_opencode_request_id"] {
            evidence.removeValue(forKey: key)
        }
        let fingerprint = (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]))
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        return AgentAttentionContext(
            eventIdentity: identifier(["event_id", "eventId", "message_id", "uuid"]) ?? fingerprint,
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
