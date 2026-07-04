import Foundation

extension CMUXCLI {
    func claudeAssistantMessageFromHookPayload(_ object: [String: Any]?) -> String? {
        guard let object else { return nil }
        let keys = [
            "last_assistant_message",
            "lastAssistantMessage",
            "assistantPreamble",
            "assistant_preamble",
            "assistant_response",
            "assistantResponse",
        ]
        let extra = (object["extra"] as? [String: Any]) ?? [:]
        let message = firstString(in: object, keys: keys)
            ?? firstString(in: extra, keys: keys)
        guard let message else { return nil }
        let normalized = normalizedSingleLine(message)
        guard !isJSONBlobAssistantMessage(normalized) else { return nil }
        return normalized.isEmpty ? nil : normalized
    }

    func isJSONBlobAssistantMessage(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return false
        }
        return true
    }

    /// These literals mirror Claude Code's Notification hook copy. If matching
    /// fails, cmux gracefully shows the original body; extend the set when
    /// Claude Code changes that external copy.
    func isGenericClaudeNotificationBody(_ body: String) -> Bool {
        let normalized = normalizedSingleLine(body)
        let placeholders: Set<String> = [
            "Claude is waiting for your input",
            "Claude needs your input",
            "Claude needs your attention"
        ]
        return placeholders.contains(normalized)
    }

    func containsCompletionCue(_ lowercasedText: String) -> Bool {
        notificationCueTokens(lowercasedText).contains { token in
            token == "done"
                || token == "succeed"
                || token == "succeeded"
                || token.hasPrefix("complet")
                || token.hasPrefix("finish")
                || token.hasPrefix("success")
        }
    }

    func containsWaitingCue(_ lowercasedText: String) -> Bool {
        let tokens = notificationCueTokens(lowercasedText)
        for (index, token) in tokens.enumerated() {
            let previous = index > 0 ? tokens[index - 1] : nil
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if token == "idle" {
                return true
            }
            if token == "wait" || token == "waiting" || token == "awaiting" {
                return true
            }
            if token == "prompt", previous == "idle" || previous == "input" || previous == "user" {
                return true
            }
            if token == "input" {
                if previous == "need" || previous == "needs" || previous == "needed"
                    || previous == "require" || previous == "requires" || previous == "required"
                    || previous == "request" || previous == "requests" || previous == "requested"
                    || previous == "wait" || previous == "waiting" || previous == "awaiting"
                    || previous == "user" || previous == "your"
                    || next == "needed" || next == "required" || next == "requested" {
                    return true
                }
            }
            if token == "question", lowercasedText.contains("?") || tokens.contains(where: {
                $0 == "answer" || $0 == "respond" || $0 == "response" || $0 == "reply"
                    || $0 == "choose" || $0 == "confirm" || $0 == "continue"
            }) {
                return true
            }
        }
        return false
    }

    func notificationCueTokens(_ lowercasedText: String) -> [Substring] {
        lowercasedText.split { !$0.isLetter && !$0.isNumber }
    }

    func sanitizeNotificationField(_ value: String) -> String {
        return normalizedSingleLine(value)
            .replacingOccurrences(of: "|", with: "¦")
    }

    func notificationPayload(
        title: String,
        subtitle: String,
        body: String,
        meta: String? = nil
    ) -> String {
        let base = "\(sanitizeNotificationField(title))|\(sanitizeNotificationField(subtitle))|\(sanitizeNotificationField(body))"
        // `meta` is a structured, delimiter-safe tag (see `notifyMeta`): it has no
        // "|" or spaces, so it is NOT sanitized and rides as a 4th pipe segment.
        // Omitting it reproduces the exact 3-field payload every legacy caller sends.
        guard let meta, !meta.isEmpty else { return base }
        return base + "|" + meta
    }

    /// Delimiter-safe meta segment. Categorized forms serialize as
    /// `c=<category>;p=<0|1>` with optional `;a=<agent-id>`; uncategorized
    /// agent notifications use `a=<agent-id>`. No "|" or spaces, so it survives
    /// the pipe-delimited payload and the app's strict parser.
    func notifyMeta(_ category: AgentHookNotifyCategory, pending: Bool, agentId: String? = nil) -> String {
        let base = "c=\(category.rawValue);p=\(pending ? 1 : 0)"
        guard let agentId = normalizedNotifyAgentId(agentId) else { return base }
        return "\(base);a=\(agentId)"
    }

    func notifyMeta(agentId: String) -> String? {
        normalizedNotifyAgentId(agentId).map { "a=\($0)" }
    }

    func normalizedNotifyAgentId(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...32).contains(value.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= 0x61 && byte <= 0x7A)
                      || (byte >= 0x30 && byte <= 0x39)
                      || byte == 0x2D
              }) else {
            return nil
        }
        return value
    }
}
