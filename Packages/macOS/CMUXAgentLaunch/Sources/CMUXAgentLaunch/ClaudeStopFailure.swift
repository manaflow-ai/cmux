import Foundation

/// Why a Claude Code turn ended on an API failure, read from a `StopFailure`
/// hook payload.
///
/// Claude Code fires `StopFailure` instead of `Stop` when a turn ends on an
/// API error. The payload carries `error` (`rate_limit`, `overloaded`,
/// `authentication_failed`, `server_error`, ...), an optional
/// `error_details`, and `last_assistant_message`, which for this event is the
/// rendered API error text. The session is still alive at its prompt but no longer
/// working, so cmux must neither keep it "Running" nor call it a completed
/// turn.
///
/// ```swift
/// let failure = ClaudeStopFailure(hookPayload: [
///     "hook_event_name": "StopFailure",
///     "error": "rate_limit",
///     "last_assistant_message": "You've hit your weekly limit · resets Oct 3 at 9am",
/// ])
/// // failure?.reason == .usageLimit, failure?.resetsAt == "Oct 3 at 9am"
/// ```
public struct ClaudeStopFailure: Equatable, Sendable {
    /// The user-facing failure class.
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// The account's usage limit is exhausted until a reset time.
        case usageLimit
        /// A transient request rate limit without an account usage reset.
        case rateLimited
        /// The API connection dropped or reset mid-response.
        case connectionDropped
        /// The API reported it is overloaded.
        case overloaded
        /// Authentication failed or the account is on hold.
        case authentication
        /// A billing problem blocks the request.
        case billing
        /// The response hit the maximum output token limit.
        case outputLimit
        /// Any other API failure.
        case apiError
    }

    /// The failure class.
    public let reason: Reason
    /// The reset time quoted by a usage-limit message (for example
    /// `Oct 3 at 9am`), when the message has one.
    public let resetsAt: String?
    /// The single-line error message, when the payload has one.
    public let message: String?

    /// Creates a failure from explicit values.
    public init(reason: Reason, resetsAt: String? = nil, message: String? = nil) {
        self.reason = reason
        self.resetsAt = resetsAt
        self.message = message
    }

    /// Reads a `StopFailure` hook payload. Returns `nil` for any other hook
    /// event, so a `Stop` payload keeps its normal completion path.
    public init?(hookPayload: [String: Any]?) {
        guard let hookPayload,
              let event = Self.string(hookPayload, keys: ["hook_event_name", "hookEventName"]),
              Self.normalizedEventName(event) == "stopfailure" else {
            return nil
        }
        let errorType = Self.string(hookPayload, keys: ["error", "error_type", "errorType"])
        let message = Self.string(
            hookPayload,
            keys: [
                "last_assistant_message", "lastAssistantMessage", "error_message", "errorMessage",
                "error_details", "errorDetails",
            ]
        ).map(Self.singleLine)
        let reason = Self.classify(errorType: errorType, message: message)
        self.init(
            reason: reason,
            resetsAt: reason == .usageLimit ? message.flatMap(Self.resetTime(in:)) : nil,
            message: message
        )
    }

    /// The `agent.error.reported` journal detail: a stable failure-class
    /// token, then the message. Auto-resume reads the token to tell a
    /// transient failure (`overloaded`, `rate_limit`, `connection_dropped`)
    /// from one a retry cannot fix (`usage_limit`, `authentication_failed`).
    public var journalDetail: String {
        let token = switch reason {
        case .usageLimit: "usage_limit"
        case .rateLimited: "rate_limit"
        case .connectionDropped: "connection_dropped"
        case .overloaded: "overloaded"
        case .authentication: "authentication_failed"
        case .billing: "billing_error"
        case .outputLimit: "max_output_tokens"
        case .apiError: "api_error"
        }
        guard let message, !message.isEmpty else { return token }
        return "\(token): \(message)"
    }

    /// Whether `eventName` names Claude Code's `StopFailure` hook event.
    public static func isStopFailureEvent(_ eventName: String?) -> Bool {
        eventName.map(normalizedEventName) == "stopfailure"
    }

    static func classify(errorType: String?, message: String?) -> Reason {
        let text = (message ?? "").lowercased()
        switch errorType?.lowercased() {
        case "rate_limit":
            return isUsageLimitMessage(text) ? .usageLimit : .rateLimited
        case "overloaded":
            return .overloaded
        case "authentication_failed", "account_on_hold":
            return .authentication
        case "billing_error":
            return .billing
        case "max_output_tokens":
            return .outputLimit
        default:
            break
        }
        if isConnectionMessage(text) { return .connectionDropped }
        if text.contains("overloaded") { return .overloaded }
        if isUsageLimitMessage(text) { return .usageLimit }
        return .apiError
    }

    /// Extracts the reset time from messages such as
    /// `You've hit your weekly limit · resets Oct 3 at 9am` or
    /// `5-hour limit reached ∙ resets 3pm (America/New_York)`.
    static func resetTime(in message: String) -> String? {
        guard let range = message.range(of: "resets ", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        var tail = message[range.upperBound...]
        if let end = tail.firstIndex(where: { "·∙•(|\n".contains($0) }) {
            tail = tail[..<end]
        }
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        return trimmed
    }

    private static func isUsageLimitMessage(_ text: String) -> Bool {
        // Account usage limits name the window ("5-hour limit", "weekly
        // limit") or quote a reset time. A bare "Rate limit reached" is a
        // transient 429, not an exhausted plan.
        ["resets", "usage limit", "hit your", "hour limit", "weekly limit", "session limit"]
            .contains { text.contains($0) }
    }

    private static func isConnectionMessage(_ text: String) -> Bool {
        ["connection", "econnreset", "econnrefused", "etimedout", "socket hang up", "network", "fetch failed"]
            .contains { text.contains($0) }
    }

    private static func normalizedEventName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
