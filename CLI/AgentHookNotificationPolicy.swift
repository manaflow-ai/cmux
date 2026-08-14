import Foundation

enum AgentHookNotificationStatus: String, Codable {
    case idle
    case needsInput
    case error
}

/// Category tag the app uses to gate agent notifications by user config.
/// Serialized into the `notify_target_async` payload's optional meta segment.
enum AgentHookNotifyCategory: String {
    case turnComplete = "turn-complete"
    case needsPermission = "needs-permission"
    case idleReminder = "idle-reminder"
    case other

    /// Delimiter-safe meta segment: `c=<category>;p=<0|1>`. `.other` is the
    /// explicit ungated category and never rides the wire.
    func metaSegment(pending: Bool) -> String? {
        guard self != .other else { return nil }
        return "c=\(rawValue);p=\(pending ? 1 : 0)"
    }
}

struct AgentHookNotificationSummary {
    /// Maximum number of characters retained in a notification body.
    static let maxBodyLength = 180

    /// Keeps notification bodies bounded while preserving a readable suffix marker.
    static func truncatedBody(_ value: String) -> String {
        guard value.count > maxBodyLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxBodyLength - 1))
        return String(value[..<index]) + "…"
    }

    let subtitle: String
    let body: String
    let status: AgentHookNotificationStatus?
    let isFallback: Bool
    /// Which user-facing notification setting gates this alert, decided by the
    /// classifier alongside subtitle/status so "Permission" and "Waiting" cues
    /// (both `.needsInput`) gate under their own settings. `.other` is the
    /// deliberate ungated always-deliver category, reserved for errors.
    var notifyCategory: AgentHookNotifyCategory
}

enum AgentHookNotificationClassifier {
    static func classify(
        displayName: String,
        signal: String,
        message: String,
        isFallback: Bool
    ) -> AgentHookNotificationSummary {
        // Stop banners are the only place where a provider error can replace a
        // completion classification. Notification hooks also carry free-form
        // assistant text, so keep this promotion scoped to an explicit stop
        // signal to avoid turning ordinary prose into an error alert.
        let abnormalStopClassifier = AgentHookAbnormalStopClassifier()
        if abnormalStopClassifier.isStopSignal(signal),
           let abnormal = abnormalStopClassifier.summary(
               displayName: displayName,
               signal: signal,
               message: message,
               isFallback: isFallback
           ) {
            return abnormal
        }

        let lower = "\(signal) \(message)".lowercased()
        // Only a stop event can be a user abort. Notification and pre-tool
        // events may contain permission prose mentioning a user's request.
        let isUserInitiatedStop = abnormalStopClassifier.isStopSignal(signal)
            && abnormalStopClassifier.isUserInitiatedStop(
                signal: signal,
                message: message
            )
        if !isUserInitiatedStop,
           (lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt")) {
            let body = message.isEmpty
                ? String(localized: "agent.generic.notification.body.approvalNeeded", defaultValue: "Approval needed")
                : message
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.permission", defaultValue: "Permission"),
                body: AgentHookNotificationSummary.truncatedBody(body),
                status: .needsInput,
                isFallback: isFallback,
                notifyCategory: .needsPermission
            )
        }
        if !isUserInitiatedStop,
           (lower.contains("error") || lower.contains("failed") || lower.contains("failure") || lower.contains("exception")) {
            let body = message.isEmpty
                ? String.localizedStringWithFormat(
                    String(localized: "agent.generic.notification.body.reportedError", defaultValue: "%@ reported an error"),
                    displayName
                )
                : message
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error"),
                body: AgentHookNotificationSummary.truncatedBody(body),
                status: .error,
                isFallback: isFallback,
                notifyCategory: .other
            )
        }
        if containsCompletionCue(lower) {
            let body = message.isEmpty
                ? String(localized: "agent.generic.notification.body.taskCompleted", defaultValue: "Task completed")
                : message
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed"),
                body: AgentHookNotificationSummary.truncatedBody(body),
                status: .idle,
                isFallback: isFallback,
                notifyCategory: .turnComplete
            )
        }
        if containsWaitingCue(lower) {
            let body = message.isEmpty
                ? String(localized: "agent.generic.notification.body.waitingForInput", defaultValue: "Waiting for input")
                : message
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.waiting", defaultValue: "Waiting"),
                body: AgentHookNotificationSummary.truncatedBody(body),
                status: .needsInput,
                isFallback: isFallback,
                notifyCategory: .idleReminder
            )
        }
        if !message.isEmpty {
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention"),
                body: AgentHookNotificationSummary.truncatedBody(message),
                status: nil,
                isFallback: isFallback,
                notifyCategory: .idleReminder
            )
        }
        let body = String.localizedStringWithFormat(
            String(localized: "agent.generic.notification.body.needsAttention", defaultValue: "%@ needs your attention"),
            displayName
        )
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention"),
            body: body,
            status: .needsInput,
            isFallback: true,
            notifyCategory: .idleReminder
        )
    }

    static func isGrokInternalSessionNotification(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.hasPrefix("sessionnotification {")
            || lowercasedMessage.contains("hookexecution {")
            || lowercasedMessage.contains("event_name: user_prompt_submit")
            || lowercasedMessage.contains(#""event_name":"user_prompt_submit""#)
    }

    static func isGrokGenericTurnCompletion(_ message: String) -> Bool {
        message.range(
            of: #"^turn complete(?:d)? in \d+(?:\.\d+)?s\.?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func containsCompletionCue(_ lowercasedText: String) -> Bool {
        notificationCueTokens(lowercasedText).contains { token in
            token == "done"
                || token == "succeed"
                || token == "succeeded"
                || token.hasPrefix("complet")
                || token.hasPrefix("finish")
                || token.hasPrefix("success")
        }
    }

    static func containsWaitingCue(_ lowercasedText: String) -> Bool {
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

    static func notificationCueTokens(_ lowercasedText: String) -> [Substring] {
        lowercasedText.split { !$0.isLetter && !$0.isNumber }
    }

}

enum AgentHookNotificationPolicy {
    static let dedupeEligibleAgents: Set<String> = ["grok", "antigravity", "hermes-agent"]

    static func notificationTitle(
        agentName: String,
        displayName: String,
        surfaceTitle: String?
    ) -> String {
        guard agentName == "pi",
              let surfaceTitle = surfaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !surfaceTitle.isEmpty else {
            return displayName
        }
        if surfaceTitle.caseInsensitiveCompare(displayName) == .orderedSame
            || surfaceTitle.range(
                of: "\(displayName) · ",
                options: [.anchored, .caseInsensitive]
            ) != nil {
            return surfaceTitle
        }
        return "\(displayName) · \(surfaceTitle)"
    }

    /// Stable per-session fingerprint. Grok 0.2.91 emits an identical generic
    /// "Tool permission requested" Notification for every tool step, even in
    /// auto-approve mode where nothing awaits the user; those repeats dedupe by
    /// body/status. Novel permission text still delivers because the body hash
    /// changes, and prompt-submit clears the store for a new turn.
    static func dedupeFingerprint(
        agentName: String,
        sessionId: String,
        status: AgentHookNotificationStatus?,
        category: AgentHookNotifyCategory,
        body: String
    ) -> String? {
        guard dedupeEligibleAgents.contains(agentName), !sessionId.isEmpty else {
            return nil
        }
        if status == .idle {
            return "idle-turn"
        }
        return "\(status?.rawValue ?? "attention"):\(stableHash(of: body))"
    }

    static func preservesDedupeAcrossSessionStart(agentName: String) -> Bool {
        agentName == "grok"
    }

    static func stableHash(of value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
