import Foundation

extension CMUXCLI {
    /// A persisted lifecycle is only a hint: attention can outlive a failed
    /// session-file write. Ask the live surface owner before suppressing work.
    func claudeHookLiveStateAllowsRunningSkip(
        client: SocketClient,
        session: ClaudeHookSessionRecord?
    ) -> Bool {
        guard let session,
              let workspaceID = UUID(uuidString: session.workspaceId),
              let surfaceID = UUID(uuidString: session.surfaceId) else { return false }
        let params: [String: Any] = [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "include_claude_hook_state": true
        ]
        // Reserve the rest of the five-second hook budget for the existing
        // resume path if the app is busy or does not support this read yet.
        guard let response = try? client.sendV2(
            method: "agent.resolve_delivery_target", params: params, responseTimeout: 0.5
        ), response["source"] as? String == "surface",
           let resolvedID = response["surface_id"] as? String,
           UUID(uuidString: resolvedID) == surfaceID,
           let resolvedWorkspaceID = response["workspace_id"] as? String,
           UUID(uuidString: resolvedWorkspaceID) == workspaceID else { return false }
        // A moved pane must take the existing re-home path once, even when its
        // live lifecycle is already Running, to repair the persisted owner.
        return response["claude_hook_can_skip_running"] as? Bool == true
    }
}
