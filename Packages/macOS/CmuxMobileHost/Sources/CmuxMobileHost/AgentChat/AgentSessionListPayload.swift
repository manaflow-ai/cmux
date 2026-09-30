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
    /// Default inactivity window used by the settled projection.
    public static let defaultSettledIdleThreshold: TimeInterval = 2 * 60 * 60
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
    public func json(_ record: AgentChatSessionRecord, now: Date, settledIdleThreshold: TimeInterval = AgentSessionListPayload.defaultSettledIdleThreshold) -> [String: Any] {
        let rank = record.state.attentionRank
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
        let inputAt = record.lastUserInputAt
        let outputAt = record.lastAgentOutputAt
        let idleSince = max(inputAt ?? record.lastActivityAt, outputAt ?? record.lastActivityAt)
        let idleFor = max(0, now.timeIntervalSince(idleSince))
        json["idle_for_seconds"] = idleFor
        json["turn_state"] = Self.turnState(for: record)
        if let inputAt { json["last_user_input_at"] = formatter.string(from: inputAt) }
        if let outputAt { json["last_agent_output_at"] = formatter.string(from: outputAt) }
        if let branch = record.branch { json["branch"] = branch }
        if let worktree = record.worktree { json["worktree"] = worktree }
        json["linked_prs"] = record.linkedPullRequests.map { pr in
            ["number": pr.number, "state": pr.state, "title": pr.title ?? NSNull()]
        }
        json["linked_prs_resolved"] = record.pullRequestsResolved || record.workingDirectory == nil
        let settled = Self.isSettled(record: record, idleFor: idleFor, threshold: settledIdleThreshold)
        json["settled"] = settled
        json["settled_reason"] = Self.settledReason(record: record, idleFor: idleFor, threshold: settledIdleThreshold)
        if let since = record.state.attentionStateSince {
            json["state_since"] = formatter.string(from: since)
            json["state_age_seconds"] = record.state.attentionStateAgeSeconds(now: now)
        }
        if let title = record.title, !title.isEmpty { json["title"] = title }
        json["last_output"] = record.lastOutput.flatMap(AgentSessionOutputPreview.cleaned) ?? NSNull()
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
    /// Records are ordered by ``Swift/Collection/orderedByAttention()`` here
    /// rather than by the caller, so every client of this verb gets triage order
    /// without re-implementing it. `state_counts` covers the records in this
    /// reply, so a caller that scoped the request to one workspace gets that
    /// workspace's totals.
    public func list(records: [AgentChatSessionRecord], now: Date) -> [String: Any] {
        let ordered = records.orderedByAttention()
        let counts = ordered.attentionCounts()
        // Built from the ranks themselves so the wire names here cannot drift
        // from ``AgentSessionAttentionRank/wireName``, which is what `state`
        // reports on each session and what the CLI's `--state` accepts.
        var stateCounts: [String: Int] = ["total": counts.total]
        for rank in AgentSessionAttentionRank.allCases {
            stateCounts[rank.wireName] = counts[rank]
        }
        return [
            "sessions": ordered.map { json($0, now: now) },
            "count": ordered.count,
            "state_counts": stateCounts,
            "generated_at": formatter.string(from: now),
        ]
    }

    private static func turnState(for record: AgentChatSessionRecord) -> String {
        switch record.state {
        case .working: return "working"
        case .needsInput: return "waiting_on_user"
        case .idle, .ended: return record.hasFinishedTurn ? "turn_finished" : "working"
        }
    }

    private static func isSettled(record: AgentChatSessionRecord, idleFor: TimeInterval, threshold: TimeInterval) -> Bool {
        guard turnState(for: record) == "turn_finished", idleFor >= threshold else { return false }
        guard record.pullRequestsResolved || record.workingDirectory == nil else { return false }
        return record.linkedPullRequests.allSatisfy { ["MERGED", "CLOSED"].contains($0.state.uppercased()) }
    }

    private static func settledReason(record: AgentChatSessionRecord, idleFor: TimeInterval, threshold: TimeInterval) -> String {
        guard turnState(for: record) == "turn_finished" else { return "turn_not_finished" }
        guard idleFor >= threshold else { return "idle_below_threshold" }
        guard record.pullRequestsResolved || record.workingDirectory == nil else { return "pr_lookup_pending" }
        if let open = record.linkedPullRequests.first(where: { $0.state.uppercased() == "OPEN" }) {
            return "open_pr_\(open.number)"
        }
        if record.linkedPullRequests.contains(where: { !["MERGED", "CLOSED"].contains($0.state.uppercased()) }) {
            return "pr_state_unknown"
        }
        return "turn_finished_and_idle"
    }
}
