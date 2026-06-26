import Foundation

extension WorkstreamEvent.HookEventName {
    /// Whether this hook event is a blocking decision that warrants pulling the
    /// user's attention to the owning workspace: a tool permission, a plan
    /// approval, or a question. Keeping this as one predicate (rather than
    /// branching per event at each call site) is what makes the attention
    /// surface uniform across every event type and agent routed through
    /// `feed.push` — a new blocking event type only has to be added here.
    public var isBlockingDecision: Bool {
        switch self {
        case .permissionRequest, .exitPlanMode, .askUserQuestion:
            return true
        default:
            return false
        }
    }
}

extension WorkstreamEvent {
    /// Maps a feed `source` (agent id) to the agent-lifecycle status key the
    /// sidebar reads. Claude reports under `claude_code`; every other agent
    /// keys its status by its own source name. Returning the agent's own key
    /// is what lets the existing per-agent resume hooks (e.g. Claude's
    /// `pre-tool-use`) clear the needs-input badge once the agent continues.
    private static let lifecycleStatusKeyOverrides = [
        "claude": "claude_code",
    ]

    /// Resolves the agent-lifecycle status key for a feed `source` string.
    public static func lifecycleStatusKey(forSource source: String) -> String {
        lifecycleStatusKeyOverrides[source] ?? source
    }

    /// Resolves the `(workspace, surface)` an attention overlay should target.
    /// The workspace prefers the event's live `workspace_id` (the running
    /// terminal's CMUX_WORKSPACE_ID, a raw UUID) so a stale hook-session map
    /// can't redirect attention to the wrong workspace; it falls back to the
    /// session store when the event omits a parseable id. The surface comes
    /// from the session store only when its workspace matches the resolved
    /// workspace, so a stale entry can't point the panel elsewhere.
    public func resolveAttentionTarget() -> (workspaceId: UUID, surfaceId: UUID?)? {
        let sessionMatch: (workspaceId: UUID, surfaceId: UUID?)? = {
            let resolver = HookSessionResolver()
            guard let parsed = resolver.parse(sessionId),
                  let resolved = resolver.lookup(agent: parsed.agent, sessionId: parsed.sessionId),
                  let workspaceId = UUID(uuidString: resolved.workspaceId)
            else { return nil }
            return (workspaceId, UUID(uuidString: resolved.surfaceId))
        }()

        let eventWorkspaceId = workspaceId.flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let workspaceId = eventWorkspaceId ?? sessionMatch?.workspaceId else {
            return nil
        }
        // Only trust the session store's surface if it belongs to the
        // workspace we're actually targeting.
        let surfaceId = (sessionMatch?.workspaceId == workspaceId) ? sessionMatch?.surfaceId : nil
        return (workspaceId, surfaceId)
    }
}
