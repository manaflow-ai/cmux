import Foundation

/// Replays authoritative rollout completion through the regular Codex Stop path.
struct CodexTranscriptMonitorStopReplay {
    let commandArguments: [String]
    let payload: String
    let workspaceId: String
    let surfaceId: String?

    init?(
        sessionId: String,
        turnId: String?,
        transcriptPath: String?,
        workspaceId: String,
        surfaceId: String?,
        lastAssistantMessage: String?
    ) {
        guard !sessionId.isEmpty, !workspaceId.isEmpty else { return nil }
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId

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
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let payload = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Do not pin the replay to the monitor's original pane. The Codex
        // process can move between the monitor and terminal completion; the
        // regular Stop resolver can then re-home the session through the live
        // surface binding before projecting Idle/Completed state.
        self.commandArguments = ["stop"]
        self.payload = payload
    }
}
