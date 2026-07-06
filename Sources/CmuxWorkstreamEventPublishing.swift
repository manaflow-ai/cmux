import Foundation
import CMUXAgentLaunch

extension CmuxEventBus {
    // swiftlint:disable:next discouraged_optional_collection
    func publishWorkstreamEvent(_ event: WorkstreamEvent, phase: String, result: [String: Any]? = nil) {
        var payload = Self.workstreamPayload(event)
        payload["phase"] = phase
        if let result {
            payload["result"] = result
        }

        publish(
            name: "agent.hook.\(event.hookEventName.rawValue)",
            category: "agent",
            source: event.source,
            workspaceId: event.workspaceId,
            payload: payload
        )

        publish(
            name: "feed.item.\(phase)",
            category: "feed",
            source: event.source,
            workspaceId: event.workspaceId,
            payload: payload
        )

        if phase == "received" {
            Task { @MainActor in
                FleetAppHost.shared.handleWorkstreamEvent(event)
            }
        }
    }

    static func workstreamPayload(_ event: WorkstreamEvent) -> [String: Any] {
        var payload: [String: Any] = [
            "session_id": event.sessionId,
            "hook_event_name": event.hookEventName.rawValue,
            "_source": event.source,
            "workspace_id": event.workspaceId ?? NSNull(),
            "cwd": event.cwd ?? NSNull(),
            "tool_name": event.toolName ?? NSNull(),
            "_opencode_request_id": event.requestId ?? NSNull(),
            "_ppid": event.ppid ?? NSNull(),
            "_received_at": Self.isoTimestamp(event.receivedAt)
        ]
        var redactedFields: [String] = []
        if let toolInputJSON = event.toolInputJSON {
            payload["tool_input"] = NSNull()
            payload["tool_input_length"] = toolInputJSON.count
            redactedFields.append("tool_input")
        }
        if let context = event.context, !context.isEmpty {
            payload["context"] = NSNull()
            if let contextLength = encodedByteCount(context) {
                payload["context_length"] = contextLength
            }
            redactedFields.append("context")
        }
        if let extraFieldsJSON = event.extraFieldsJSON {
            payload["extra_fields"] = NSNull()
            payload["extra_fields_length"] = extraFieldsJSON.count
            redactedFields.append("extra_fields")
        }
        if !redactedFields.isEmpty {
            payload["redacted_fields"] = redactedFields
        }
        return payload
    }

    private static func encodedByteCount<T: Encodable>(_ value: T) -> Int? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value).count
    }
}
