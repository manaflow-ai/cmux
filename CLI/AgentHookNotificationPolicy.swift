import CmuxSettings
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

    var soundAlertType: NotificationSoundAlertType? {
        switch self {
        case .turnComplete: return .turnDone
        case .needsPermission, .idleReminder: return .needsInput
        case .other: return nil
        }
    }

    /// Delimiter-safe legacy meta segment: `c=<category>;p=<0|1>`. The
    /// contextual overload below can add agent, alert, and approval identity.
    func metaSegment(pending: Bool) -> String? {
        metaSegment(pending: pending, agentKind: nil, isSubagent: nil)
    }

    /// Meta segment carrying an opaque Codex approval correlation id.
    /// `.other` is the explicit ungated category and never rides the wire.
    func metaSegment(pending: Bool, approvalID: String? = nil) -> String? {
        metaSegment(
            pending: pending,
            approvalID: approvalID,
            agentKind: nil,
            isSubagent: nil
        )
    }

    /// Extended meta segment carrying optional agent-event context for the
    /// app's notification-policy hooks. Correlated approval ids retain the
    /// historical `a=` spelling; ordinary agent context uses the same field
    /// for a validated registry slug.
    /// `c=<category>;p=<0|1>[;a=<agent-kind-or-approval-id>][;n=<0|1>][;k=<uuid>]`
    /// is emitted in this canonical field order. Invalid optional fields are
    /// dropped rather than risking the app-side parser folding the whole meta
    /// back into the body.
    func metaSegment(
        pending: Bool,
        agentKind: String?,
        isSubagent: Bool?,
        correlationKey: String? = nil
    ) -> String? {
        metaSegment(
            pending: pending,
            approvalID: nil,
            agentKind: agentKind,
            isSubagent: isSubagent,
            correlationKey: correlationKey
        )
    }

    private func metaSegment(
        pending: Bool,
        approvalID: String?,
        agentKind: String?,
        isSubagent: Bool?,
        correlationKey: String? = nil
    ) -> String? {
        guard self != .other else { return nil }
        var segment = "c=\(rawValue);p=\(pending ? 1 : 0)"
        if self == .needsPermission, let approvalID {
            segment += ";a=\(approvalID)"
        } else if let agentKind, Self.isValidAgentKindTag(agentKind) {
            segment += ";a=\(agentKind)"
        }
        if let isSubagent {
            segment += ";n=\(isSubagent ? 1 : 0)"
        }
        if let correlationKey, Self.isValidCorrelationKey(correlationKey) {
            segment += ";k=\(UUID(uuidString: correlationKey)?.uuidString.lowercased() ?? correlationKey)"
        }
        return segment
    }

    /// Mirror of the app-side `AgentNotificationMeta` slug grammar: 1-64 ASCII
    /// characters of `[A-Za-z0-9._-]`, excluding `.` and `..`. Both sides must
    /// agree exactly or the app folds the meta back into the notification body.
    static func isValidAgentKindTag(_ value: String) -> Bool {
        NotificationSoundOverrideContext.isValidAgentID(value)
    }

    func metaSegment(
        pending: Bool,
        agentID: String,
        alertType: NotificationSoundAlertType? = nil,
        isSubagent: Bool? = nil,
        correlationKey: String? = nil
    ) -> String? {
        let resolvedAlertType: NotificationSoundAlertType?
        switch self {
        case .turnComplete: resolvedAlertType = alertType ?? .turnDone
        case .needsPermission, .idleReminder: resolvedAlertType = alertType ?? .needsInput
        case .other: resolvedAlertType = alertType
        }
        guard let resolvedAlertType,
              let context = NotificationSoundOverrideContext(
                  agentID: agentID,
                  alertType: resolvedAlertType
              ),
              (self == .other
                ? resolvedAlertType == .errorStalled
                : soundAlertType == resolvedAlertType) else {
            return nil
        }
        var segment = "c=\(rawValue);p=\(pending ? 1 : 0);a=\(context.agentID)"
        if let isSubagent {
            segment += ";n=\(isSubagent ? 1 : 0)"
        }
        segment += ";s=\(context.alertType.rawValue)"
        if let correlationKey, Self.isValidCorrelationKey(correlationKey) {
            segment += ";k=\(UUID(uuidString: correlationKey)?.uuidString.lowercased() ?? correlationKey)"
        }
        return segment
    }

    /// Correlation keys are opaque UUIDs used only to clear one notification.
    static func isValidCorrelationKey(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
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
        var latestTurnContext: [String: Any]?
        for line in rolloutLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }
            if latestTurnContext == nil {
                latestTurnContext = payload
            }
            guard let requestedTurnID else {
                return reviewRoute(in: payload)
            }
            if firstString(in: payload, keys: ["turn_id", "turnId"]) == requestedTurnID {
                return reviewRoute(in: payload)
            }
        }

        // Older rollout writers omitted turn_id. Only trust that fallback on
        // the newest context; never borrow a route from a known older turn.
        if let latestTurnContext,
           firstString(in: latestTurnContext, keys: ["turn_id", "turnId"]) == nil {
            return reviewRoute(in: latestTurnContext)
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
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 8_192 else {
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
        guard trimmedEntry.count >= 7, trimmedEntry.count <= 512,
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
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
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
                  globMatches(basePattern, value: commandBase) else {
                return false
            }
            if !argumentPattern.contains("*"), !argumentPattern.contains("?") {
                return commandArguments == argumentPattern
                    || commandArguments.hasPrefix(argumentPattern + " ")
            }
            return globMatches(argumentPattern, value: commandArguments)
        }
        if !pattern.contains("*"), !pattern.contains("?") {
            // Cursor's Shell(prefix) form allows the prefix plus additional
            // arguments, so Shell(git status) matches git status --short.
            return normalizedCommand == pattern
                || normalizedCommand.hasPrefix(pattern + " ")
        }

        return globMatches(pattern, value: normalizedCommand)
    }

    private static func globMatches(_ pattern: String, value: String) -> Bool {
        guard pattern.utf8.count <= 512, value.utf8.count <= 8_192 else { return false }
        let patternScalars = Array(pattern.unicodeScalars)
        let valueScalars = Array(value.unicodeScalars)
        var patternIndex = 0
        var valueIndex = 0
        var lastStarIndex: Int?
        var valueAtLastStar = 0

        while valueIndex < valueScalars.count {
            if patternIndex < patternScalars.count,
               (patternScalars[patternIndex] == valueScalars[valueIndex]
                || patternScalars[patternIndex] == "?") {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < patternScalars.count,
                      patternScalars[patternIndex] == "*" {
                lastStarIndex = patternIndex
                valueAtLastStar = valueIndex
                patternIndex += 1
            } else if let lastStarIndex {
                patternIndex = lastStarIndex + 1
                valueAtLastStar += 1
                valueIndex = valueAtLastStar
            } else {
                return false
            }
        }
        while patternIndex < patternScalars.count, patternScalars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternScalars.count
    }

    /// Redacts credentials before a command reaches durable hook state or UI.
    static func redactSensitiveCommand(_ value: String) -> String {
        let boundedValue = value.utf8.count > 8_192
            ? String(decoding: value.utf8.prefix(8_191), as: UTF8.self) + "…"
            : value
        let patterns: [(pattern: String, replacement: String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?:~|/)[^\s\"']+"#, "<path>"),
            (#"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b"#, "<token>"),
            (#"\b(?:sk|rk|sess|token|key|secret|api[_-]?key)[A-Za-z0-9._:-]{8,}\b"#, "<token>"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#, "Bearer <token>"),
            (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "<token>"),
            (#"(?i)\b(?:authorization|proxy-authorization)\s*:\s*[^\s'\";&|]+(?:\s+[^\s'\";&|]+)*"#, "<credential>:<token>"),
            (#"(?i)\b(?:x[-_])?(?:api[-_]?key|password|secret|token|authorization|cookie)\s*:\s*(?:Bearer\s+)?(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, "<credential>:<token>"),
            (#"(?i)(?:^|\s)--?[A-Za-z0-9]*(?:api[-_]?key|access[-_]?key|password|secret|token|authorization|cookie|passphrase)[A-Za-z0-9_-]*(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)--?(?:api[-_]?key|password|secret|token|authorization|cookie)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, "<credential>=<token>"),
            (#"(?i)(?:^|\s)(?:-u|--user)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)(?:^|\s)(?:--passphrase|--password|--pass|--auth|--credential)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)(?:^|\s)(?:-a|-p|-pass)(?:=|\s+|(?=[^\s]))(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)\b[A-Za-z_]*(?:api[_-]?key|password|secret|token|authorization|cookie)[A-Za-z0-9_]*\s*=\s*(?:'[^']*'|\"[^\"]*\"|[^\s;&|]+)"#, "<credential>=<token>"),
            (#"(?i)\b(?:api[_-]?key|password|secret|token|authorization|cookie)\s*=\s*[^\s;&|]+"#, "<credential>=<token>"),
            (#"\b[A-Za-z0-9_-]{24,}\b"#, "<token>"),
        ]
        return patterns.reduce(boundedValue) { partial, entry in
            partial.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    static let cursorNativeApprovalResponse = #"{"permission":"ask"}"#

    /// Returns Cursor's explicit CLI approval-mode override, when present.
    static func cursorApprovalModeOverride(arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            let rawValue: String?
            if argument == "--mode", index + 1 < arguments.count {
                rawValue = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--mode=") {
                rawValue = String(argument.dropFirst("--mode=".count))
                index += 1
            } else {
                index += 1
                continue
            }
            guard let rawValue else { continue }
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["allowlist", "auto-review", "unrestricted"].contains(normalized) {
                return normalized
            }
        }
        return nil
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
