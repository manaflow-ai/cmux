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
        metaSegment(pending: pending, agentKind: nil, isSubagent: nil)
    }

    /// Extended meta segment carrying optional agent-event context for the
    /// app's notification-policy hooks:
    /// `c=<category>;p=<0|1>[;a=<agent-kind>][;n=<0|1>]` (canonical field
    /// order; `a=` is the stable lowercase agent slug, `n=` marks a nested
    /// subagent session). An agent kind that fails slug validation is dropped
    /// rather than risking the app-side parser folding the whole meta back
    /// into the body.
    func metaSegment(pending: Bool, agentKind: String?, isSubagent: Bool?) -> String? {
        guard self != .other else { return nil }
        var segment = "c=\(rawValue);p=\(pending ? 1 : 0)"
        if let agentKind, Self.isValidAgentKindTag(agentKind) {
            segment += ";a=\(agentKind)"
        }
        if let isSubagent {
            segment += ";n=\(isSubagent ? 1 : 0)"
        }
        return segment
    }

    /// Mirror of the app-side `AgentNotificationMeta` slug grammar: 1-64
    /// characters of `[a-z0-9._-]`. Both sides must agree exactly or the app
    /// folds the meta back into the notification body.
    static func isValidAgentKindTag(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLowercase || character.isNumber
                    || character == "." || character == "_" || character == "-")
        }
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

enum AgentHookNotificationClassifier {
    static func classify(
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
                body: truncate(body, maxLength: 180),
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
                body: truncate(body, maxLength: 180),
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
                body: truncate(body, maxLength: 180),
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
                body: truncate(body, maxLength: 180),
                status: .needsInput,
                isFallback: isFallback,
                notifyCategory: .idleReminder
            )
        }
        if !message.isEmpty {
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention"),
                body: truncate(message, maxLength: 180),
                status: nil,
                isFallback: isFallback,
                notifyCategory: .idleReminder
            )
        }
        // No usable message and no matching cue: nothing is fabricated. The
        // empty body tells callers to reuse a stored summary or skip the
        // banner, and the nil status makes no lifecycle claim — the old
        // "%@ needs your attention" needs-input fallback is deliberately
        // gone (semantic journal events carry state now).
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention"),
            body: "",
            status: nil,
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

    private static func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
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

    /// Cursor invokes `beforeShellExecution` before its native permission
    /// evaluator and does not include that evaluator's decision in the hook
    /// payload. Its protocol does expose whether the command is sandboxed, so
    /// an explicit unsandboxed value is the only conservative candidate we can
    /// use to ask for the native prompt; it is not authoritative approval
    /// state (Cursor's allowlist and Run Everything decisions are internal).
    /// Missing or malformed values remain telemetry-only. Completion/failure
    /// handlers must correlate against the pending command record.
    /// Known local Run Everything, Shell(...) allow, and Shell(...) deny
    /// entries are filtered before this fallback because team/server policy and
    /// smart-mode decisions are not present in the hook payload.
    static func shouldRequestCursorNativeApproval(
        payload: [String: Any]?,
        approvalMode: String? = nil,
        allowedShellCommands: [String] = [],
        deniedShellCommands: [String] = []
    ) -> Bool {
        guard payload?["sandbox"] as? Bool == false else { return false }
        // Without a locally known allowlist mode there is no authoritative
        // signal that this callback is waiting. Keep the event telemetry-only
        // rather than manufacturing an uncorrelatable Needs input state.
        guard approvalMode == "allowlist",
              let command = payload?["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard !deniedShellCommands.contains(where: {
            cursorShellAllowlistEntryMatches($0, command: command)
        }) else {
            return false
        }
        return !allowedShellCommands.contains {
            cursorShellAllowlistEntryMatches($0, command: command)
        }
    }

    private static func cursorShellAllowlistEntryMatches(
        _ entry: String,
        command: String
    ) -> Bool {
        let trimmedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEntry.count >= 7,
              trimmedEntry.range(
                  of: #"^Shell\("#,
                  options: [.regularExpression, .caseInsensitive]
              ) != nil,
              trimmedEntry.last == ")" else {
            return false
        }
        let patternStart = trimmedEntry.index(trimmedEntry.startIndex, offsetBy: 6)
        let patternEnd = trimmedEntry.index(before: trimmedEntry.endIndex)
        let pattern = String(trimmedEntry[patternStart..<patternEnd])
        let normalizedCommand = command
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, !normalizedCommand.isEmpty else { return false }

        let commandParts = normalizedCommand.split(
            maxSplits: 1,
            whereSeparator: { $0.isWhitespace }
        )
        let commandBase = commandParts.first.map(String.init) ?? ""
        let commandArguments = commandParts.count > 1 ? String(commandParts[1]) : ""

        if pattern.contains(":") {
            let components = pattern.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard let basePattern = components.first.map(String.init),
                  let argumentPattern = components.dropFirst().first.map(String.init),
                  basePattern == commandBase else {
                return false
            }
            return globMatches(argumentPattern, value: commandArguments)
        }
        if !pattern.contains("*"), !pattern.contains("?") {
            // Cursor's Shell(commandBase) form allows any arguments for that
            // command; matching the whole string would reject valid entries
            // such as Shell(git) for a git status command.
            return pattern == commandBase
        }

        return globMatches(pattern, value: normalizedCommand)
    }

    private static func globMatches(_ pattern: String, value: String) -> Bool {
        var regex = "^"
        for scalar in pattern.unicodeScalars {
            switch scalar {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            default:
                regex += NSRegularExpression.escapedPattern(for: String(scalar))
            }
        }
        regex += "$"
        return value.range(of: regex, options: .regularExpression) != nil
    }

    static let cursorNativeApprovalResponse = #"{"permission":"ask"}"#

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
