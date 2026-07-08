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

func agentHookClassifyNotification(
    displayName: String,
    signal: String,
    message: String,
    isFallback: Bool
) -> AgentHookNotificationSummary {
    let lower = "\(signal) \(message)".lowercased()
    if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
        let body = message.isEmpty
            ? String(localized: "agent.generic.notification.body.approvalNeeded", defaultValue: "Approval needed")
            : message
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.permission", defaultValue: "Permission"),
            body: truncateAgentHookNotification(body, maxLength: 180),
            status: .needsInput,
            isFallback: isFallback,
            notifyCategory: .needsPermission
        )
    }
    if lower.contains("error") || lower.contains("failed") || lower.contains("failure") || lower.contains("exception") {
        let body = message.isEmpty
            ? String.localizedStringWithFormat(
                String(localized: "agent.generic.notification.body.reportedError", defaultValue: "%@ reported an error"),
                displayName
            )
            : message
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error"),
            body: truncateAgentHookNotification(body, maxLength: 180),
            status: .error,
            isFallback: isFallback,
            notifyCategory: .other
        )
    }
    if agentHookNotificationContainsCompletionCue(lower) {
        let body = message.isEmpty
            ? String(localized: "agent.generic.notification.body.taskCompleted", defaultValue: "Task completed")
            : message
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed"),
            body: truncateAgentHookNotification(body, maxLength: 180),
            status: .idle,
            isFallback: isFallback,
            notifyCategory: .turnComplete
        )
    }
    if agentHookNotificationContainsWaitingCue(lower) {
        let body = message.isEmpty
            ? String(localized: "agent.generic.notification.body.waitingForInput", defaultValue: "Waiting for input")
            : message
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.waiting", defaultValue: "Waiting"),
            body: truncateAgentHookNotification(body, maxLength: 180),
            status: .needsInput,
            isFallback: isFallback,
            notifyCategory: .idleReminder
        )
    }
    if !message.isEmpty {
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention"),
            body: truncateAgentHookNotification(message, maxLength: 180),
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

func agentHookIsGrokInternalSessionNotification(_ message: String) -> Bool {
    let lowercasedMessage = message.lowercased()
    return lowercasedMessage.hasPrefix("sessionnotification {")
        || lowercasedMessage.contains("hookexecution {")
        || lowercasedMessage.contains("event_name: user_prompt_submit")
        || lowercasedMessage.contains(#""event_name":"user_prompt_submit""#)
}

func agentHookIsGrokGenericTurnCompletion(_ message: String) -> Bool {
    message.range(
        of: #"^turn complete(?:d)? in \d+(?:\.\d+)?s\.?$"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}

func agentHookNotificationContainsCompletionCue(_ lowercasedText: String) -> Bool {
    agentHookNotificationCueTokens(lowercasedText).contains { token in
        token == "done"
            || token == "succeed"
            || token == "succeeded"
            || token.hasPrefix("complet")
            || token.hasPrefix("finish")
            || token.hasPrefix("success")
    }
}

func agentHookNotificationContainsWaitingCue(_ lowercasedText: String) -> Bool {
    let tokens = agentHookNotificationCueTokens(lowercasedText)
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

private func agentHookNotificationCueTokens(_ lowercasedText: String) -> [Substring] {
    lowercasedText.split { !$0.isLetter && !$0.isNumber }
}

private func truncateAgentHookNotification(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else { return value }
    let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
    return String(value[..<index]) + "…"
}

/// Stable per-session fingerprint. Grok 0.2.91 emits identical generic
/// needs-input telemetry for every tool step, so eligible agents dedupe by
/// status/body across short-lived hook CLI processes.
func agentHookNotificationDedupeFingerprint(
    agentName: String,
    sessionId: String,
    status: AgentHookNotificationStatus?,
    category: AgentHookNotifyCategory,
    body: String
) -> String? {
    guard agentHookNotificationDedupeEligibleAgent(agentName), !sessionId.isEmpty else {
        return nil
    }
    if status == .idle {
        return "idle-turn"
    }
    return "\(status?.rawValue ?? "attention"):\(stableAgentHookNotificationHash(of: body))"
}

private func agentHookNotificationDedupeEligibleAgent(_ agentName: String) -> Bool {
    agentName == "grok" || agentName == "antigravity"
}

func agentHookNotificationPreservesDedupeAcrossSessionStart(agentName: String) -> Bool {
    agentName == "grok"
}

/// Grok 0.2.91 emits identical needs-input telemetry for every tool step, even
/// in auto-approve mode, and can spawn multiple internal sessions per
/// invocation. Treat Grok needs-input notifications as pane state updates; only
/// terminal `.idle` and `.error` statuses should banner.
func agentHookNotificationSuppressesNeedsInputBanner(agentName: String) -> Bool {
    agentName == "grok"
}

func agentHookNotifyCategory(forStoredStatus status: AgentHookNotificationStatus?) -> AgentHookNotifyCategory {
    switch status {
    case .idle?:
        return .turnComplete
    case .error?:
        return .other
    case .needsInput?, nil:
        return .idleReminder
    }
}

private func stableAgentHookNotificationHash(of value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    var hex = String(hash, radix: 16, uppercase: false)
    if hex.count < 16 {
        hex = String(repeating: "0", count: 16 - hex.count) + hex
    }
    return hex
}
