import Foundation

extension CMUXCLI {
    private static let legacyClaudeBlockingAttentionRequestId = "legacy-session-blocker"

    func claudeBlockingAttentionRequestId(
        toolUseId: String?
    ) -> String {
        nonEmptyClaudeHookIdentifier(toolUseId)
            ?? Self.legacyClaudeBlockingAttentionRequestId
    }

    func beginClaudeBlockingAttention(
        client: SocketClient,
        sessionId: String,
        toolUseId: String?,
        workspaceId: String,
        surfaceId: String,
        owner: ClaudeHookSessionRecord?,
        title: String,
        subtitle: String,
        body: String
    ) {
        guard let owner,
              let ownerPID = owner.pid,
              ownerPID > 0,
              ownerPID <= Int(Int32.max),
              let ownerPIDStartSeconds = owner.pidStartSeconds,
              let ownerPIDStartMicroseconds = owner.pidStartMicroseconds,
              ownerPIDStartSeconds >= 0,
              (0..<1_000_000).contains(ownerPIDStartMicroseconds) else {
            return
        }
        let params: [String: Any] = [
            "source": "claude",
            "session_id": sessionId,
            "request_id": claudeBlockingAttentionRequestId(toolUseId: toolUseId),
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "title": title,
            "subtitle": subtitle,
            "body": body,
            "ppid": ownerPID,
            "ppid_start_seconds": ownerPIDStartSeconds,
            "ppid_start_microseconds": ownerPIDStartMicroseconds,
        ]
        _ = try? client.sendV2(method: "feed.attention.begin", params: params)
    }

    func endClaudeBlockingAttention(
        client: SocketClient,
        sessionId: String,
        toolUseId: String?
    ) {
        _ = try? client.sendV2(method: "feed.attention.end", params: [
            "source": "claude",
            "session_id": sessionId,
            "request_id": claudeBlockingAttentionRequestId(toolUseId: toolUseId),
        ])
    }

    /// A turn boundary supersedes any tool callback that never arrived (for
    /// example after native permission denial or interruption). Feed-owned
    /// requests are harmless no-ops here; bypass-mode requests release their
    /// exact transient owner without clearing any pane-wide attention.
    func endClaudeBlockingAttentionForTurnBoundary(
        client: SocketClient,
        sessionId: String,
        record: ClaudeHookSessionRecord?
    ) {
        if let pendingIds = record?.pendingBlockingToolUseIds {
            for toolUseId in pendingIds {
                endClaudeBlockingAttention(
                    client: client,
                    sessionId: sessionId,
                    toolUseId: toolUseId
                )
            }
            return
        }
        guard record?.agentLifecycle == .needsInput else { return }
        endClaudeBlockingAttention(
            client: client,
            sessionId: sessionId,
            toolUseId: nil
        )
    }
}
