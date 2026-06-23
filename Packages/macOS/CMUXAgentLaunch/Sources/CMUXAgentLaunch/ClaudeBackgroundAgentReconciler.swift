import Foundation

/// A live Claude Code background agent, as reported by `claude agents --json`.
///
/// cmux's `claude` wrapper mints a fresh `--session-id <uuid>` for every create-new launch
/// (`Resources/bin/cmux-claude-wrapper`). When such a launch was meant to resume a
/// backgrounded agent, the minted session is empty and writes no transcript — an
/// unrecoverable "ghost" id — while the user's real conversation stays alive as a separate
/// background-agent session in the Claude Code daemon under a different id. The daemon's
/// `claude agents --json` is the authoritative source for that real id; cmux uses it to
/// reconcile a ghost panel back to the real conversation.
/// https://github.com/manaflow-ai/cmux/issues/6622
public struct ClaudeBackgroundAgentSnapshot: Sendable, Equatable {
    /// The session id to resume — the full conversation id (`sessionId` when present in the
    /// daemon JSON, otherwise the short `id`). Only a full session id resolves a transcript,
    /// so a short-id fallback simply fails to match and reconciliation degrades to a no-op.
    public let sessionId: String
    /// The working directory the agent was started under (`cwd` in the daemon JSON).
    public let cwd: String?
    /// The agent kind (`"background"` for supervisor-managed sessions).
    public let kind: String

    public init(sessionId: String, cwd: String?, kind: String) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
    }
}

/// Maps a cmux panel that is showing a transcript-less ghost Claude session to the real
/// background-agent session id for the same working directory, so resume targets the real
/// conversation (`claude --resume <real-id>`) instead of the empty ghost id and never a
/// fresh `--session-id`. https://github.com/manaflow-ai/cmux/issues/6622
///
/// Pure value logic over primitives so it is testable in isolation; the daemon query that
/// produces `backgroundAgents` lives in the app target.
public struct ClaudeBackgroundAgentReconciler: Sendable, Equatable {
    public init() {}

    /// The real background-agent session id to reconcile a ghost panel to, or `nil` to leave
    /// the panel's tracked id unchanged.
    ///
    /// Reconciliation is intentionally conservative: it fires only when exactly one live
    /// background agent matches the panel's working directory (and is not the ghost id
    /// itself). A working directory with zero or several background agents is ambiguous, so
    /// the panel keeps its current id rather than risk attaching to the wrong conversation.
    ///
    /// - Parameters:
    ///   - ghostSessionId: the panel's currently tracked (ghost) session id.
    ///   - panelCwd: the working directory the panel's agent was launched in.
    ///   - backgroundAgents: live background agents from `claude agents --json`.
    public func reconciledSessionId(
        forGhostSessionId ghostSessionId: String,
        panelCwd: String?,
        backgroundAgents: [ClaudeBackgroundAgentSnapshot]
    ) -> String? {
        guard let panelCwd = Self.normalizedPath(panelCwd) else { return nil }
        let ghost = ghostSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = backgroundAgents.filter { agent in
            agent.kind == "background"
                && !agent.sessionId.isEmpty
                && agent.sessionId != ghost
                && Self.normalizedPath(agent.cwd) == panelCwd
        }
        guard matches.count == 1 else { return nil }
        return matches[0].sessionId
    }

    /// Parses `claude agents --json` output into background-agent snapshots.
    ///
    /// The daemon prints a JSON array of session objects. cmux only needs the resumable
    /// session id, the working directory, and the kind; everything else is ignored. The full
    /// session id is read from `sessionId` when present (required for `claude --resume`),
    /// falling back to the short `id`. Malformed output yields an empty array so the caller
    /// degrades to leaving the panel unchanged.
    public static func parse(agentsJSON: Data) -> [ClaudeBackgroundAgentSnapshot] {
        guard let array = try? JSONSerialization.jsonObject(with: agentsJSON) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { object in
            let rawId = (object["sessionId"] as? String) ?? (object["id"] as? String)
            guard let sessionId = rawId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionId.isEmpty else {
                return nil
            }
            let cwd = (object["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = (object["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ClaudeBackgroundAgentSnapshot(
                sessionId: sessionId,
                cwd: (cwd?.isEmpty == false) ? cwd : nil,
                kind: kind
            )
        }
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return (trimmed as NSString).standardizingPath
    }
}
