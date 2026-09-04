import Foundation

extension CMUXCLI {
    private enum AtomcodeStopReason {
        case stopped
        case providerError
        case timeout
        case cancelled

        /// Returns a safe, known outcome for AtomCode's terminal hook payload.
        /// Unknown values deliberately fall back to the generic error summary.
        init?(rawValue: String?) {
            guard let rawValue else { return nil }
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "", options: .regularExpression)
                .lowercased()
            switch normalized {
            case "stopped":
                self = .stopped
            case "providererror":
                self = .providerError
            case "timeout":
                self = .timeout
            case "cancelled":
                self = .cancelled
            default:
                return nil
            }
        }

        /// Localized notification text that never includes provider payload data.
        var localizedBody: String {
            switch self {
            case .stopped:
                return String(localized: "agent.atomcode.notification.body.stopped", defaultValue: "AtomCode stopped")
            case .providerError:
                return String(localized: "agent.atomcode.notification.body.providerError", defaultValue: "AtomCode provider error")
            case .timeout:
                return String(localized: "agent.atomcode.notification.body.timeout", defaultValue: "AtomCode request timed out")
            case .cancelled:
                return String(localized: "agent.atomcode.notification.body.cancelled", defaultValue: "AtomCode request was cancelled")
            }
        }
    }

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
        let reason = firstString(in: object, keys: ["stop_reason", "stopReason"])
        let body = AtomcodeStopReason(rawValue: reason)?.localizedBody
            ?? String.localizedStringWithFormat(
                String(
                    localized: "agent.generic.notification.body.reportedError",
                    defaultValue: "%@ reported an error"
                ),
                def.displayName
            )
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
