import Foundation

extension CMUXCLI {
    /// True when a Claude `Stop`/`Notification` payload reports unfinished
    /// background work: any `background_tasks` entry still `running`, or a
    /// non-empty `session_crons`. A nil rawObject or absent keys (Claude
    /// 2.1.145) yield false, preserving older clients' behavior.
    func hasActiveClaudeBackgroundWork(_ parsedInput: ClaudeHookParsedInput) -> Bool {
        guard let obj = parsedInput.rawObject else { return false }
        if let crons = obj["session_crons"] as? [Any], !crons.isEmpty { return true }
        if let tasks = obj["background_tasks"] as? [[String: Any]] {
            return tasks.contains { ($0["status"] as? String) == "running" }
        }
        return false
    }

    func summarizeClaudeHookNotification(parsedInput: ClaudeHookParsedInput) -> (subtitle: String, body: String) {
        guard let object = parsedInput.object else {
            if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
                return classifyClaudeNotification(signal: fallback, message: fallback)
            }
            // No payload at all: nothing to say. An empty body tells the
            // caller to reuse the stored session summary or skip the banner.
            return ("Waiting", "")
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"])
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "error", "description"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "error", "description"])
        ]
        let message = messageCandidates.compactMap { $0 }.first ?? ""
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? String(localized: "agent.generic.notification.body.approvalNeeded", defaultValue: "Approval needed") : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? String(localized: "cli.claude-hook.notification.body.error", defaultValue: "Claude reported an error") : message
            return ("Error", body)
        }
        if AgentHookNotificationClassifier.containsCompletionCue(lower) {
            let body = message.isEmpty ? String(localized: "agent.generic.notification.body.taskCompleted", defaultValue: "Task completed") : message
            return ("Completed", body)
        }
        if AgentHookNotificationClassifier.containsWaitingCue(lower) {
            let body = message.isEmpty ? String(localized: "agent.generic.notification.body.waitingForInput", defaultValue: "Waiting for input") : message
            return ("Waiting", body)
        }
        // Use the message directly when there is one. A payload with no
        // usable message yields an empty body; callers reuse a stored summary
        // or skip the banner rather than fabricating attention text.
        if !message.isEmpty {
            return ("Attention", message)
        }
        return ("Attention", "")
    }

    /// Classifier tokens are internal protocol values; only this boundary renders them.
    func localizedClaudeNotificationSubtitle(_ token: String) -> String {
        switch token {
        case "Permission": String(localized: "agent.generic.notification.subtitle.permission", defaultValue: "Permission")
        case "Waiting": String(localized: "agent.generic.notification.subtitle.waiting", defaultValue: "Waiting")
        case "Error": String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error")
        case "Completed": String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed")
        case "Attention": String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention")
        default: token
        }
    }
}
