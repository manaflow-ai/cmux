import Foundation

/// A coding-agent status reported by a remote agent's own lifecycle hook, carried
/// over the tmux control stream as the `@cmux_agent` user option (Option C in
/// `docs/investigations/remote-agent-status-sidebar.md`).
///
/// The remote hook runs `tmux set -p @cmux_agent '<json>'` on each lifecycle event
/// (SessionStart/UserPromptSubmit → working, Stop → idle), and cmux already
/// receives the new value as a `%subscription-changed cmux_agent_<paneId> … : <json>`
/// line on the live `tmux -CC` stream — no socket, no relay, no remote cmux CLI.
/// This type is the pure parser for that JSON value; the subscription wiring lives
/// in ``RemoteTmuxControlConnection`` and the sidebar write in
/// ``RemoteTmuxSessionMirror``.
struct RemoteTmuxAgentStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case running   // session started / attached, no turn in flight
        case working   // a turn is in flight (prompt submitted, tools running)
        case idle      // turn finished / stopped, waiting on the user

        /// The lifecycle words the hooks emit, mapped to a state. Tolerant of a few
        /// synonyms so the remote hook script can use whichever the agent provides.
        init?(hookWord raw: String) {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "working", "busy", "active", "start", "running-turn": self = .working
            case "idle", "stop", "done", "complete", "finished", "waiting": self = .idle
            case "running", "session-start", "start-session", "ready": self = .running
            default: return nil
            }
        }
    }

    /// Agent label as the remote reported it (e.g. `claude`, `codex`). Lowercased,
    /// non-empty.
    let agent: String
    let state: State
    /// Optional model id (already stripped of any `[1m]` retention suffix).
    let model: String?
    /// Optional short title / current activity line.
    let title: String?

    /// Parses the `@cmux_agent` option value. Accepts a JSON object with
    /// `{agent, state, model?, title?}`. Returns `nil` for an empty value (the
    /// hook clears the option to remove the chip) or a value missing the required
    /// `agent`/`state`.
    static func parse(_ raw: String) -> RemoteTmuxAgentStatus? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let agentRaw = (obj["agent"] as? String)?
                .trimmingCharacters(in: .whitespaces).lowercased(),
              !agentRaw.isEmpty,
              let stateRaw = obj["state"] as? String,
              let state = State(hookWord: stateRaw)
        else { return nil }

        let model = (obj["model"] as? String).flatMap(normalizeModel)
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteTmuxAgentStatus(
            agent: agentRaw,
            state: state,
            model: model,
            title: (title?.isEmpty == false) ? title : nil
        )
    }

    /// Strips the `[1m]` retention suffix Bedrock model ids carry, matching the
    /// local Claude metadata parser, and trims. Returns `nil` when empty.
    private static func normalizeModel(_ raw: String) -> String? {
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasSuffix("[1m]") { model.removeLast(4) }
        model = model.trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? nil : model
    }
}
