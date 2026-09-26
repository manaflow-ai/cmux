import CmuxAgentHooks
import Foundation

extension AgentHookAbnormalStopClass {
    /// Localized subtitle for a classified provider stop.
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

extension AgentHookAbnormalStopClassifier {
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
        guard !isSensitiveProviderDetail(normalized) else {
            return failureClass?.safeNotificationBody ?? AgentHookAbnormalStopClass.generic.safeNotificationBody
        }
        return AgentHookNotificationSummary.truncatedBody(normalized)
    }
}
