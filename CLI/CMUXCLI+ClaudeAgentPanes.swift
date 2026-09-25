import Foundation

extension CMUXCLI {
    /// Returns Claude Code's PreToolUse middleware response for a Task/Agent
    /// spawn. Claude only opens a teammate pane when the spawn has a name;
    /// adding one here keeps plain `claude` and `cmux claude-teams` on the same
    /// path without requiring users to remember a team-specific prompt.
    func claudeAgentPaneHookResponse(
        input: ClaudeHookParsedInput,
        environment: [String: String]
    ) -> String {
        guard environment["CMUX_AGENT_PANES_ENABLED"] == "1",
              let raw = input.rawObject,
              let toolName = firstString(in: raw, keys: ["tool_name", "toolName"]),
              toolName == "Task" || toolName == "Agent",
              var toolInput = raw["tool_input"] as? [String: Any]
                ?? raw["toolInput"] as? [String: Any] else {
            return "{}"
        }

        if let existingName = toolInput["name"] as? String,
           !existingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "{}"
        }

        let description = (toolInput["description"] as? String)
            ?? (toolInput["prompt"] as? String)
            ?? (toolInput["subagent_type"] as? String)
            ?? "agent"
        let slug = description
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(3)
            .joined(separator: "-")
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        toolInput["name"] = "\(slug.isEmpty ? "agent" : slug)-\(suffix)"

        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": toolInput,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
