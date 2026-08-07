import Foundation

extension TerminalController {
    /// Ephemeral attention is a UI mutation, so these methods intentionally run
    /// on the control socket's main-actor lane. They never activate or focus the
    /// app, and unlike `feed.push` they perform no durable Feed/event writes.
    func v2FeedTransientAttentionBegin(params: [String: Any]) -> V2CallResult {
        guard let source = transientAttentionString(params["source"], maxBytes: 80),
              let sessionId = transientAttentionString(params["session_id"], maxBytes: 512),
              let requestId = transientAttentionString(params["request_id"], maxBytes: 512),
              let workspaceId = transientAttentionUUID(params["workspace_id"]),
              let surfaceId = transientAttentionUUID(params["surface_id"]),
              let title = transientAttentionString(params["title"], maxBytes: 512)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.attention.begin requires source, session_id, request_id, workspace_id, surface_id, and title",
                data: nil
            )
        }
        let subtitle = transientAttentionString(params["subtitle"], maxBytes: 512) ?? ""
        let body = transientAttentionString(params["body"], maxBytes: 4_096) ?? ""
        let active = FeedCoordinator.shared.beginTransientBlockingAttention(
            source: source,
            sessionId: sessionId,
            requestId: requestId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body
        )
        return .ok(["active": active])
    }

    func v2FeedTransientAttentionEnd(params: [String: Any]) -> V2CallResult {
        guard let source = transientAttentionString(params["source"], maxBytes: 80),
              let sessionId = transientAttentionString(params["session_id"], maxBytes: 512),
              let requestId = transientAttentionString(params["request_id"], maxBytes: 512)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.attention.end requires source, session_id, and request_id",
                data: nil
            )
        }
        let ended = FeedCoordinator.shared.endTransientBlockingAttention(
            source: source,
            sessionId: sessionId,
            requestId: requestId
        )
        return .ok(["ended": ended])
    }

    private func transientAttentionString(_ rawValue: Any?, maxBytes: Int) -> String? {
        guard let value = rawValue as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxBytes else { return nil }
        return trimmed
    }

    private func transientAttentionUUID(_ rawValue: Any?) -> UUID? {
        guard let value = transientAttentionString(rawValue, maxBytes: 64) else { return nil }
        return UUID(uuidString: value)
    }
}
