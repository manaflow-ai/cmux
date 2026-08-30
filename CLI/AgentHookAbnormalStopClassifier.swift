import Foundation

/// Stable provider failure classes that terminate a turn without completing it.
/// These classes intentionally require recognizable error cues so ordinary
/// assistant prose, user interrupts, and ambiguous stops remain fail-closed.
enum AgentHookAbnormalStopClass: Equatable {
    case capacity
    case quota
    case rateLimit
    case timeout
    case authentication
    case network
    case generic

    var localizedSubtitle: String {
        switch self {
        case .capacity:
            return String(localized: "agent.generic.notification.subtitle.capacity", defaultValue: "Model at capacity")
        case .quota:
            return String(localized: "agent.generic.notification.subtitle.quota", defaultValue: "Quota exhausted")
        case .rateLimit:
            return String(localized: "agent.generic.notification.subtitle.rateLimit", defaultValue: "Rate limited")
        case .timeout:
            return String(localized: "agent.generic.notification.subtitle.timeout", defaultValue: "Request timed out")
        case .authentication:
            return String(localized: "agent.generic.notification.subtitle.authentication", defaultValue: "Authentication error")
        case .network:
            return String(localized: "agent.generic.notification.subtitle.network", defaultValue: "Network error")
        case .generic:
            return String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error")
        }
    }

    /// Safe fallback body used when a provider message contains implementation
    /// details that must not cross the notification boundary.
    var safeNotificationBody: String {
        String(
            localized: "agent.generic.notification.body.safeProviderError",
            defaultValue: "The agent stopped unexpectedly. Try again or inspect the terminal for details."
        )
    }
}

struct AgentHookAbnormalStopClassifier {
    /// Creates a stateless classifier for one managed-agent stop boundary.
    init() {}

    /// Builds the ungated error summary for a recognized provider stop.
    func summary(
        displayName _: String,
        signal: String,
        message: String,
        isFallback: Bool
    ) -> AgentHookNotificationSummary? {
        guard isStopSignal(signal),
              let failureClass = abnormalStopClass(signal: signal, message: message) else {
            return nil
        }
        let body = safeNotificationBody(message: message, failureClass: failureClass)
        return AgentHookNotificationSummary(
            subtitle: failureClass.localizedSubtitle,
            body: AgentHookNotificationSummary.truncatedBody(body),
            status: .error,
            isFallback: isFallback,
            notifyCategory: .other
        )
    }

    /// Keeps upstream provider text out of classified notifications while
    /// retaining legacy unclassified summaries when they contain no diagnostics.
    ///
    /// - Parameters:
    ///   - message: Provider-supplied terminal text.
    ///   - failureClass: The recognized class, when one is available, used to
    ///     choose a stable fallback body.
    /// - Returns: A bounded body safe to send over the notification protocol.
    func safeNotificationBody(
        message: String,
        failureClass: AgentHookAbnormalStopClass? = nil
    ) -> String {
        let normalized = message
            .replacingOccurrences(of: "\u{1B}", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let failureClass {
            return failureClass.safeNotificationBody
        }
        guard !normalized.isEmpty else {
            return AgentHookAbnormalStopClass.generic.safeNotificationBody
        }
        guard !containsSensitiveProviderDetail(normalized) else {
            return failureClass?.safeNotificationBody ?? AgentHookAbnormalStopClass.generic.safeNotificationBody
        }
        return AgentHookNotificationSummary.truncatedBody(normalized)
    }

    /// Returns the stable failure class for a provider banner, if one is
    /// present. The caller can use this predicate without choosing a UI.
    func abnormalStopClass(signal: String, message: String) -> AgentHookAbnormalStopClass? {
        guard isStopSignal(signal) else { return nil }
        let lower = "\(signal) \(message)".lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalized = lower
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let normalizedMessage = message
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // An explicit user abort is never promoted to a provider error, even
        // if stale text from a previous response is attached.
        guard !containsUserInitiatedStopCue(normalized) else { return nil }

        // A final response can mention a transient failure while still
        // completing the requested work. Only a strong provider-banner marker
        // may override an explicit completion sentence.
        // Transcript terminal event names such as `task_complete` are part of
        // the signal, not the provider's response. Evaluate completion prose
        // against the response itself so a terminal event cannot hide a real
        // capacity/timeout banner. Conversely, a response that says a
        // transient request failed but then completed remains a normal turn.
        if AgentHookNotificationClassifier.containsCompletionCue(normalizedMessage),
           !containsStrongProviderFailureCue(normalizedMessage) {
            return nil
        }

        let overloadCue = (normalized.contains("overloaded") || normalized.contains("overload"))
            && (
                normalized.contains("server")
                    || normalized.contains("model")
                    || normalized.contains("provider")
                    || normalized.contains("service")
                    || normalized.contains("api")
                    || normalized.contains("error")
                    || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "overloaded"
                    || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "overload"
            )
        let status529Cue = normalized.contains("529") && (
            normalized.contains("error")
                || normalized.contains("overload")
                || normalized.contains("capacity")
                || normalized.contains("unavailable")
                || normalized.contains("http 529")
                || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "529"
        )
        let capacityCue = normalized.contains("at capacity")
            || normalized.contains("over capacity")
            || normalized.contains("capacity reached")
            || normalized.contains("capacity error")
            || normalized.contains("model capacity")
            || normalized.contains("capacity exceeded")
            || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "capacity"
            || overloadCue
            || normalized.contains("server overloaded")
            || normalized.contains("overloaded error")
            || status529Cue
        let messageTokens = AgentHookNotificationClassifier.notificationCueTokens(normalizedMessage)
        let providerCapacityQualifiers: Set<Substring> = [
            "model", "server", "provider", "service", "api", "error", "llm", "endpoint",
        ]
        let providerCapacityQualifier = messageTokens.contains {
            providerCapacityQualifiers.contains($0)
        }
        let explicitCapacityReason = [
            "capacity", "at capacity", "overload", "overloaded", "529",
            "stop capacity", "stop at capacity", "stop overload", "stop overloaded", "stop 529",
        ].contains {
            normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == $0
        }
        if capacityCue && (providerCapacityQualifier || explicitCapacityReason) {
            return .capacity
        }
        let quotaCue = normalized.contains("usage limit")
            || normalized.contains("hit your limit")
            || normalized.contains("limit reached")
            || normalized.contains("usage exhausted")
            || normalized.contains("quota exceeded")
            || normalized.contains("quota exhausted")
            || normalized.contains("quota limit")
            || normalized.contains("credit limit")
            || normalized.contains("credits exhausted")
            || normalized.contains("no remaining credits")
            || normalized.contains("out of credits")
            || normalized.contains("insufficient credits")
            || (normalized.contains("quota") && (
                normalized.contains("error")
                    || normalized.contains("reached")
                    || normalized.contains("remaining")
                    || normalized.contains("reset")
            ))
        if quotaCue {
            return .quota
        }
        if normalized.contains("rate limit")
            || normalized.contains("rate limited")
            || normalized.contains("too many requests")
            || (normalized.contains("throttl") && (
                normalized.contains("error")
                    || normalized.contains("request")
                    || normalized.contains("api")
                    || normalized.contains("provider")
                    || normalized.contains("rate")
            ))
            || (normalized.contains("429") && (
                normalized.contains("request")
                    || normalized.contains("error")
                    || normalized.contains("rate")
                    || normalized.contains("http 429")
                    || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "429"
            )) {
            return .rateLimit
        }
        let timeoutCue = normalized.contains("request timed out")
            || normalized.contains("request timeout")
            || (normalized.contains("timed out") && (
                normalized.contains("error")
                    || normalized.contains("request")
                    || normalized.contains("connection")
                    || normalized.contains("stream")
                    || normalized.contains("api")
                    || containsStrongProviderFailureCue(normalizedMessage)
            ))
            || normalized.contains("deadline exceeded")
            || normalized.contains("gateway timeout")
            || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "timeout"
            || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "etimedout"
            || (normalized.contains("timeout") && (
                normalized.contains("error")
                    || normalized.contains("failed")
                    || normalized.contains("operation")
                    || normalized.contains("connection")
                    || normalized.contains("request")
            ))
            || (normalized.contains("etimedout") && normalized.contains("error"))
        if timeoutCue {
            return .timeout
        }
        if normalized.contains("authentication error")
            || normalized.contains("auth error")
            || normalized.contains("authentication token")
            || normalized.contains("unauthorized")
            || normalized.contains("invalid api key")
            || normalized.contains("expired api key")
            || normalized.contains("token expired")
            || normalized.contains("token has expired")
            || normalized.contains("expired token")
            || normalized.contains("session expired")
            || normalized.contains("auth expired")
            || normalized.contains("login required")
            || normalized.contains("sign in to continue") {
            return .authentication
        }
        if normalized.contains("connection refused")
            || normalized.contains("connection reset")
            || normalized.contains("stream disconnected")
            || normalized.contains("network error")
            || normalized.contains("service unavailable")
            || normalized.contains("temporarily unavailable")
            || normalized.contains("502 bad gateway")
            || normalized.contains("503 service unavailable")
            || normalized.contains("504 gateway") {
            return .network
        }

        guard !AgentHookNotificationClassifier.containsCompletionCue(normalizedMessage) else {
            return nil
        }
        if containsExplicitGenericFailureCue(normalized) {
            return .generic
        }
        return nil
    }

    /// Identifies an explicit user cancellation without classifying it as a
    /// provider failure. Callers use this to discard stale error payloads.
    func isUserInitiatedStop(signal: String, message: String) -> Bool {
        containsUserInitiatedStopCue("\(signal) \(message)".lowercased())
    }

    /// Recognizes the terminal hook event names that can carry a provider
    /// banner. Other notification events remain fail-closed.
    func isStopSignal(_ signal: String) -> Bool {
        let lower = signal.lowercased()
        let tokens = AgentHookNotificationClassifier.notificationCueTokens(lower)
        if tokens.contains(where: { token in
            token == "stop"
                || token == "stopped"
                || token == "stophook"
                || token == "stopfailure"
        }) {
            return true
        }
        let compact = tokens.joined()
        return compact == "turnaborted"
            || compact == "stopfailure"
            || compact == "stophook"
            || compact == "taskcomplete"
            || compact == "turncomplete"
    }

    private func containsUserInitiatedStopCue(_ lowercasedText: String) -> Bool {
        let normalized = lowercasedText
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "=", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains("interrupted by user")
            || normalized.contains("cancelled by user")
            || normalized.contains("canceled by user")
            || normalized.contains("aborted by user")
            || normalized.contains("stopped by user")
            || normalized.contains("user cancelled")
            || normalized.contains("user canceled")
            || normalized.contains("user interrupt")
            || normalized.contains("user abort")
            || normalized == "user requested"
            || normalized.contains("user requested stop")
            || normalized.contains("user requested abort")
            || normalized.contains("user requested cancellation")
            || normalized.contains("stop requested by user")
            || normalized.contains("ctrl c")
            || normalized.contains("^c")
            || normalized.contains("keyboardinterrupt")
            || normalized.contains("keyboard interrupt")
            || normalized.contains("sigint")
            || normalized == "command /exit"
            || normalized.contains("/exit requested")
            || normalized == "/exit"
            || normalized.contains("stop cancelled")
            || normalized.contains("stop canceled")
            || normalized.contains("stop interrupted")
            || normalized.contains("stop aborted")
            || (normalized.contains("turn aborted") && (
                normalized.contains("user")
                    || normalized.contains("interrupt")
                    || normalized.contains("cancel")
            ))
            || normalized.trimmingCharacters(in: .whitespacesAndNewlines) == "interrupted"
            || normalized.trimmingCharacters(in: .whitespacesAndNewlines) == "cancelled"
            || normalized.trimmingCharacters(in: .whitespacesAndNewlines) == "canceled"
            || normalized.trimmingCharacters(in: .whitespacesAndNewlines) == "user abort"
    }

    private func containsStrongProviderFailureCue(_ lowercasedText: String) -> Bool {
        lowercasedText.contains("■")
            || lowercasedText.contains("api error")
            || lowercasedText.contains("error:")
            || lowercasedText.contains("failed:")
            || lowercasedText.contains("failure:")
            || lowercasedText.contains("overloaded error")
            || lowercasedText.contains("rate limit error")
            || lowercasedText.contains("authentication error")
            || lowercasedText.contains("server overloaded")
            || lowercasedText.contains("529")
            || lowercasedText.contains("429")
    }

    private func containsSensitiveProviderDetail(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:authorization|proxy-authorization|cookie|set-cookie|bearer|basic|api[_ -]?key|access[_ -]?token|refresh[_ -]?token)\s*[:=]"#,
            #"(?i)\b(?:request|trace|correlation|session|turn|event)[_ -]?id\s*[:=]"#,
            #"(?i)\b(?:stack trace|traceback|private key|credential|secret|payload|headers?)\b"#,
            #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
            #"https?://\S+"#,
            #"\{[^{}]{2,}\}"#,
            #"(?i)\bat\s+[A-Za-z0-9_./-]+\([^)]*\)"#,
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func containsExplicitGenericFailureCue(_ lowercasedText: String) -> Bool {
        guard !lowercasedText.contains("no error"),
              !lowercasedText.contains("without error"),
              !lowercasedText.contains("error-free") else {
            return false
        }
        return lowercasedText.contains("api error")
            || lowercasedText.contains("error:")
            || lowercasedText.contains("failed:")
            || lowercasedText.contains("failure:")
            || lowercasedText.contains("exception:")
            || lowercasedText.contains("fatal:")
            || lowercasedText.contains("fatal error")
            || lowercasedText.contains("stop failure")
            || lowercasedText.contains("stopfailure")
    }

}
