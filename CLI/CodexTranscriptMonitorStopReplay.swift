import Foundation

/// Replays authoritative rollout completion through the regular Codex Stop path.
struct CodexTranscriptMonitorStopReplay {
    let commandArguments: [String]
    let payload: String
    let agentEventTime: TimeInterval

    init?(
        sessionId: String,
        turnId: String?,
        transcriptPath: String?,
        workspaceId: String,
        surfaceId: String?,
        lastAssistantMessage: String?,
        agentEventTime: TimeInterval
    ) {
        guard !sessionId.isEmpty, !workspaceId.isEmpty else { return nil }

        var object: [String: Any] = [
            "session_id": sessionId,
            "hook_event_name": "Stop",
            "stop_hook_active": false,
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
        guard agentEventTime.isFinite, agentEventTime > 0 else { return nil }
        object["cmux_event_time"] = agentEventTime
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let payload = String(data: data, encoding: .utf8) else {
            return nil
        }

        var commandArguments = ["stop", "--workspace", workspaceId]
        if let surfaceId, !surfaceId.isEmpty {
            commandArguments += ["--surface", surfaceId]
        }
        self.commandArguments = commandArguments
        self.payload = payload
        self.agentEventTime = agentEventTime
    }
}
