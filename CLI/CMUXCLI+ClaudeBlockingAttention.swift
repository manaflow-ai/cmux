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
        title: String,
        subtitle: String,
        body: String
    ) {
        _ = try? client.sendV2(method: "feed.attention.begin", params: [
            "source": "claude",
            "session_id": sessionId,
            "request_id": claudeBlockingAttentionRequestId(toolUseId: toolUseId),
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "title": title,
            "subtitle": subtitle,
            "body": body,
        ])
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
