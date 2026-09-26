import Foundation
import CmuxAgentHooks

private func normalizedNotificationField(_ value: String) -> String {
    let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
}

extension AgentHookNotificationSummary {
    static let maxBodyLength = 180

    static func truncatedBody(_ value: String) -> String {
        guard value.count > maxBodyLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxBodyLength - 1))
        return String(value[..<index]) + "…"
    }
}

extension AgentHookNotificationClassifier {
    static func abnormalStopSummary(
        displayName: String,
        signal: String,
        message: String,
        isFallback: Bool
    ) -> AgentHookNotificationSummary? {
        let classifier = AgentHookAbnormalStopClassifier()
        guard classifier.isStopSignal(signal) else { return nil }
        return classifier.summary(
            displayName: displayName,
            signal: signal,
            message: message,
            isFallback: isFallback
        )
    }

    static func isUserInitiatedStop(signal: String, message: String) -> Bool {
        let classifier = AgentHookAbnormalStopClassifier()
        return classifier.isStopSignal(signal)
            && classifier.isUserInitiatedStop(signal: signal, message: message)
    }
}

extension CMUXCLI {
    func sanitizeNotificationField(_ value: String) -> String {
        return normalizedNotificationField(value)
            .replacingOccurrences(of: "|", with: "¦")
    }

    func notificationPayload(
        title: String,
        subtitle: String,
        body: String,
        meta: String? = nil
    ) -> String {
        let base = "\(sanitizeNotificationField(title))|\(sanitizeNotificationField(subtitle))|\(sanitizeNotificationField(body))"
        // `meta` is a structured, delimiter-safe tag: it has no
        // "|" or spaces, so it is NOT sanitized and rides as a 4th pipe segment.
        // Omitting it reproduces the exact 3-field payload every legacy caller sends.
        guard let meta, !meta.isEmpty else { return base }
        return base + "|" + meta
    }

}
