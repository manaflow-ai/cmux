public import Foundation

/// One in-flight background task an agent reported for its session: a
/// background shell, subagent, monitor, workflow or similar.
///
/// Claude Code sends the session's whole list (what `/tasks` shows) as
/// `background_tasks` in its `Stop` and `SubagentStop` hooks. The CLI
/// forwards a bounded copy, with shell commands redacted, in the hook
/// event's extra fields; the registry keeps the latest list per session.
public struct AgentChatBackgroundTask: Sendable, Equatable {
    /// The agent's task identifier.
    public let id: String
    /// Task kind as the agent labels it, e.g. "shell", "subagent", "monitor".
    public let type: String
    /// Task status as reported, e.g. "running".
    public let status: String
    /// Free-text description, when present.
    public let description: String?
    /// The redacted shell command, for shell tasks.
    public let command: String?
    /// The subagent type, for subagent tasks.
    public let agentType: String?
    /// The workflow name, for workflow tasks.
    public let name: String?

    /// Upper bound on tasks kept per session. The CLI bounds the list too;
    /// this guards the app against older or third-party senders.
    public static let capacity = 20

    public init(
        id: String,
        type: String,
        status: String,
        description: String? = nil,
        command: String? = nil,
        agentType: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.description = description
        self.command = command
        self.agentType = agentType
        self.name = name
    }

    /// Decodes `background_tasks` from a hook event's extra-fields JSON.
    ///
    /// Returns `nil` when the key is absent or not an array (older Claude
    /// Code versions omit it), so callers keep the list they have; an empty
    /// array means nothing is in flight. Entries that are not objects are
    /// skipped. An entry without an id or type (the CLI compacts oversized
    /// payloads to a bare `{"status":"running"}` marker) still counts, under
    /// a positional id.
    public static func decodeList(fromExtraFieldsJSON json: String?) -> [AgentChatBackgroundTask]? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["background_tasks"] as? [Any] else {
            return nil
        }
        var tasks: [AgentChatBackgroundTask] = []
        for (index, entry) in entries.enumerated() {
            guard tasks.count < capacity else { break }
            guard let fields = entry as? [String: Any] else { continue }
            tasks.append(AgentChatBackgroundTask(
                id: nonEmpty(fields["id"]) ?? "task-\(index)",
                type: nonEmpty(fields["type"]) ?? "task",
                status: nonEmpty(fields["status"]) ?? "unknown",
                description: nonEmpty(fields["description"]),
                command: nonEmpty(fields["command"]),
                agentType: nonEmpty(fields["agent_type"]),
                name: nonEmpty(fields["name"])
            ))
        }
        return tasks
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
