import Foundation

/// Replays authoritative rollout completion through the regular Codex Stop path.
struct CodexTranscriptMonitorStopReplay {
    let commandArguments: [String]
    let payload: String

    init?(
        sessionId: String,
        turnId: String?,
        transcriptPath: String?,
        workspaceId: String? = nil,
        surfaceId: String?,
        lastAssistantMessage: String?,
        boundary: AgentTurnBoundary,
        deferredSettlementID: UUID? = nil
    ) {
        guard !sessionId.isEmpty else { return nil }
        let workspaceId = workspaceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceId = surfaceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard workspaceId?.isEmpty == false
                || surfaceId?.isEmpty == false else {
            return nil
        }

        var object: [String: Any] = [
            "session_id": sessionId,
            "hook_event_name": "Stop",
            "stop_hook_active": false,
            "cmux_turn_boundary": boundary.rawValue,
        ]
        if let turnId, !turnId.isEmpty {
            object["turn_id"] = turnId
        }
        if let transcriptPath, !transcriptPath.isEmpty {
            object["transcript_path"] = transcriptPath
        }
        if let lastAssistantMessage, !lastAssistantMessage.isEmpty {
            object["last_assistant_message"] = lastAssistantMessage
        }
        if let deferredSettlementID {
            object["cmux_deferred_settlement_id"] =
                deferredSettlementID.uuidString
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let payload = String(data: data, encoding: .utf8) else {
            return nil
        }

        var commandArguments = ["stop"]
        if let workspaceId, !workspaceId.isEmpty {
            commandArguments += ["--workspace", workspaceId]
        }
        if let surfaceId, !surfaceId.isEmpty {
            commandArguments += ["--surface", surfaceId]
        }
        self.commandArguments = commandArguments
        self.payload = payload
    }
}
