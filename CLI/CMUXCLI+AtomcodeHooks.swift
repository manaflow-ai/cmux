import Foundation

extension CMUXCLI {
    /// AtomCode stores hooks as a named object map rather than the array-based
    /// Claude/Codex formats. Keep names stable so reinstalling cmux replaces
    /// its own entries without touching user hooks.
    static func atomcodeHookKey(agentEvent: String, feed: Bool) -> String {
        let normalized = agentEvent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .lowercased()
        return "cmux_\(feed ? "feed_" : "")\(normalized.isEmpty ? "event" : normalized)"
    }

    static func atomcodeHookEntry(
        command: String,
        agentEvent: String,
        timeoutMs: Int
    ) -> [String: Any] {
        [
            "event": agentEvent,
            "command": command,
            "timeout_ms": max(timeoutMs, 1),
        ]
    }

    /// AtomCode's StopFailure is terminal even when its reason does not happen
    /// to contain a word such as "error". Convert the verified event into the
    /// shared error summary shape used by the generic stop reducer.
    func atomcodeStopFailureSummary(
        def: AgentHookDef,
        input: ClaudeHookParsedInput
    ) -> AgentHookNotificationSummary? {
        guard def.name == "atomcode",
              let rawEvent = reportedHookEventName(from: input) else {
            return nil
        }
        let normalizedEvent = rawEvent
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard normalizedEvent == "stopfailure" else { return nil }

        let object = input.rawObject ?? input.object ?? [:]
        let reason = firstString(
            in: object,
            keys: ["stop_reason", "stopReason", "reason", "type", "kind"]
        ) ?? ""
        let message = firstString(
            in: object,
            keys: ["error", "message", "description"]
        ) ?? reason
        let body = message.isEmpty
            ? String.localizedStringWithFormat(
                String(
                    localized: "agent.generic.notification.body.reportedError",
                    defaultValue: "%@ reported an error"
                ),
                def.displayName
            )
            : truncate(normalizedSingleLine(message), maxLength: 180)
        return AgentHookNotificationSummary(
            subtitle: String(
                localized: "agent.generic.notification.subtitle.error",
                defaultValue: "Error"
            ),
            body: body,
            status: .error,
            isFallback: false,
            notifyCategory: .other
        )
    }
}
