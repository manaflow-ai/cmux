public import Foundation

/// Wire mapping for a live agent-session listing, free of AppKit and
/// controller state.
///
/// An instance owns the timestamp formatter, so building one per reply is what
/// keeps a response from allocating a formatter per session (the same reason
/// `DiffCommentPayload` is shaped this way).
///
/// Keys are snake_case and timestamps are ISO 8601 strings, matching the rest
/// of the v2 socket surface. Optional record fields are omitted rather than
/// emitted as null, so a client can test for presence.
public struct AgentSessionListPayload {
    private let formatter: ISO8601DateFormatter

    /// Creates a mapper. Pass a formatter to share one across several replies
    /// or to pin a configuration in tests.
    public init(formatter: ISO8601DateFormatter = ISO8601DateFormatter()) {
        self.formatter = formatter
    }

    /// Serializes one session.
    ///
    /// - Parameters:
    ///   - record: The registry record to map.
    ///   - now: Clock reading used for `state_age_seconds`, injected so a reply
    ///     stamps every session from one instant and tests are deterministic.
    public func json(_ record: AgentChatSessionRecord, now: Date) -> [String: Any] {
        let rank = AgentSessionAttention.rank(record.state)
        var json: [String: Any] = [
            "session_id": record.sessionID,
            "agent": record.agentKind.sourceName,
            "agent_name": record.agentKind.displayName,
            "state": rank.wireName,
            // Process-table discovery proves a session exists but not that it
            // is idle, so the registry marks such records unconfirmed. A client
            // that wants to say "idle" out loud should check this first; one
            // that only sorts can ignore it.
            "state_confirmed": record.hasHookLifecycleState,
            "attention_rank": rank.rawValue,
            "needs_attention": record.state.needsAttention,
            "last_activity_at": formatter.string(from: record.lastActivityAt),
            "children_running": record.children.reduce(into: 0) { total, child in
                if child.isRunning { total += 1 }
            },
            "version": record.version,
        ]
        if let since = AgentSessionAttention.stateSince(record.state) {
            json["state_since"] = formatter.string(from: since)
            json["state_age_seconds"] = AgentSessionAttention.stateAgeSeconds(record.state, now: now)
        }
        if let title = record.title, !title.isEmpty { json["title"] = title }
        if let cwd = record.workingDirectory, !cwd.isEmpty { json["cwd"] = cwd }
        if let workspaceID = record.workspaceID, !workspaceID.isEmpty {
            json["workspace_id"] = workspaceID
        }
        if let surfaceID = record.surfaceID, !surfaceID.isEmpty {
            json["surface_id"] = surfaceID
        }
        if let transcriptPath = record.transcriptPath, !transcriptPath.isEmpty {
            json["transcript_path"] = transcriptPath
        }
        if let pid = record.pid { json["pid"] = pid }
        if let endedAt = record.endedAt { json["ended_at"] = formatter.string(from: endedAt) }
        return json
    }

    /// Builds the `agent.sessions.list` reply.
    ///
    /// Records are ordered by ``AgentSessionAttention/ordered(_:)`` here rather
    /// than by the caller, so every client of this verb gets triage order
    /// without re-implementing it. `state_counts` covers the records in this
    /// reply, so a caller that scoped the request to one workspace gets that
    /// workspace's totals.
    public func list(records: [AgentChatSessionRecord], now: Date) -> [String: Any] {
        let ordered = AgentSessionAttention.ordered(records)
        let counts = AgentSessionAttention.counts(ordered)
        return [
            "sessions": ordered.map { json($0, now: now) },
            "count": ordered.count,
            "state_counts": [
                "needs_input": counts.needsInput,
                "working": counts.working,
                "idle": counts.idle,
                "ended": counts.ended,
                "total": counts.total,
            ],
            "generated_at": formatter.string(from: now),
        ]
    }
}
