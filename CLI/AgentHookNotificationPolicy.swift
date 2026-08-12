import CryptoKit
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

    /// Delimiter-safe meta segment: `c=<category>;p=<0|1>`, optionally with
    /// the opaque correlation id used to settle native Codex approvals.
    /// `.other` is the explicit ungated category and never rides the wire.
    func metaSegment(pending: Bool, approvalID: String? = nil) -> String? {
        guard self != .other else { return nil }
        let base = "c=\(rawValue);p=\(pending ? 1 : 0)"
        guard self == .needsPermission, let approvalID else { return base }
        return "\(base);a=\(approvalID)"
    }
}

/// Correlation shared by the generic Codex hook and the newer Feed hook.
/// `PermissionRequest` does not expose a tool-use id, so both sides derive an
/// opaque identity from the stable session/turn/tool/input tuple that the
/// request and completion share.
struct CodexApprovalNotificationIdentity: Equatable, Sendable {
    let scope: String
    let approvalID: String

    static func make(
        rawObject: [String: Any]?,
        fallbackSessionID: String?
    ) -> Self? {
        let object = rawObject ?? [:]
        guard let sessionID = firstNonemptyString(
            in: object,
            keys: ["session_id", "sessionId", "conversation_id", "conversationId"]
        ) ?? normalized(fallbackSessionID) else { return nil }
        let turnID = firstNonemptyString(in: object, keys: ["turn_id", "turnId"]) ?? ""
        let toolCall = object["toolCall"] as? [String: Any]
        let toolName = firstNonemptyString(in: object, keys: ["tool_name", "toolName"])
            ?? toolCall.flatMap { firstNonemptyString(in: $0, keys: ["name"]) }
            ?? ""
        let toolInput = object["tool_input"]
            ?? object["toolInput"]
            ?? toolCall?["args"]
        guard let canonicalToolInput = canonicalJSON(toolInput) else { return nil }
        let scopeSeed = "session=\(sessionID)\nturn=\(turnID)"
        let scope = digestPrefix(scopeSeed)
        let request = digestPrefix(
            "\(scopeSeed)\ntool=\(toolName)\ninput=\(canonicalToolInput)"
        )
        return Self(scope: scope, approvalID: "\(scope).\(request)")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func firstNonemptyString(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = normalized(object[key] as? String) {
                return value
            }
        }
        return nil
    }

    private static func canonicalJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        let wrapped: [String: Any] = ["value": value]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func digestPrefix(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum CodexApprovalReviewRoute: Equatable, Sendable {
    case user
    case autoReview
}

/// Reads Codex's effective per-turn reviewer before deciding whether a
/// `PermissionRequest` can represent user-visible work.
///
/// Codex runs permission hooks before either reviewer. Current Codex persists
/// the effective `approvals_reviewer` in the turn-context rollout item first,
/// so `auto_review` is authoritative evidence that the request will be decided
/// by Codex's reviewer rather than by the user. Older Codex versions omit the
/// field and fall back to the app-side settle window.
struct CodexApprovalNotificationPolicy: Sendable {
    static let rolloutTailBytes: UInt64 = 1024 * 1024

    /// Returns true only when a readable bounded rollout tail proves auto-review.
    func isAutoReviewed(
        rawObject: [String: Any],
        transcriptPath: String?,
        readRolloutLines: (_ path: String, _ maxBytes: UInt64) -> [String]?
    ) -> Bool {
        // An explicit user reviewer is authoritative and can never result in
        // auto-review.  Resolve that cheap in-memory case before opening and
        // parsing the rollout tail.  Keep the auto-review side fail-closed:
        // it still requires a readable transcript as proof of the effective
        // turn context.
        if reviewRoute(rawObject: rawObject, rolloutLines: []) == .user {
            return false
        }
        guard let transcriptPath = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcriptPath.isEmpty,
              let rolloutLines = readRolloutLines(transcriptPath, Self.rolloutTailBytes),
              !rolloutLines.isEmpty else {
            return false
        }
        return reviewRoute(rawObject: rawObject, rolloutLines: rolloutLines) == .autoReview
    }

    func reviewRoute(
        rawObject: [String: Any],
        rolloutLines: [String]
    ) -> CodexApprovalReviewRoute? {
        // A top-level reviewer on the request itself is authoritative, including
        // for MCP calls. Current hook payloads omit it, but accept that stronger
        // future signal before falling back to turn-wide context.
        if let direct = reviewRoute(in: rawObject) {
            return direct
        }

        // Codex Apps may override the turn's reviewer per MCP connector. The
        // hook payload does not expose that effective override, so no turn-wide
        // reviewer value is authoritative for MCP requests. Fall back to
        // correlated settling rather than risk silencing a user prompt.
        let toolCall = rawObject["toolCall"] as? [String: Any]
        let toolName = firstString(in: rawObject, keys: ["tool_name", "toolName"])
            ?? toolCall.flatMap { firstString(in: $0, keys: ["name"]) }
        if toolName?.lowercased().hasPrefix("mcp__") == true {
            return nil
        }

        for key in ["thread_settings", "threadSettings", "context"] {
            if let nested = rawObject[key] as? [String: Any],
               let route = reviewRoute(in: nested) {
                return route
            }
        }

        let requestedTurnID = firstString(
            in: rawObject,
            keys: ["turn_id", "turnId"]
        )
        guard let requestedTurnID else { return nil }
        for line in rolloutLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }
            if firstString(in: payload, keys: ["turn_id", "turnId"]) == requestedTurnID {
                return reviewRoute(in: payload)
            }
        }
        return nil
    }

    private func reviewRoute(in object: [String: Any]) -> CodexApprovalReviewRoute? {
        guard let value = firstString(
            in: object,
            keys: ["approvals_reviewer", "approvalsReviewer", "approval_reviewer", "approvalReviewer"]
        )?.lowercased() else {
            return nil
        }
        switch value {
        case "user":
            return .user
        case "auto_review", "auto-review", "guardian_subagent":
            return .autoReview
        default:
            return nil
        }
    }

    private func firstString(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let raw = object[key] as? String else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
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
