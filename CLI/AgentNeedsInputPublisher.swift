import CryptoKit
import Foundation

struct AgentNeedsInputPublisher {
    let sessionStore: any AgentNeedsInputSessionStoring
    let sendCommand: (String) throws -> String
    let notificationPayload: (String, String, String) -> String
    let surfaceOption: (String?) -> String
    let quote: (String) -> String
    let redact: (String) -> String
    let recordPersistenceError: (String, Error) -> Void
    var dedupInterval: TimeInterval = 60 * 60

    func publish(_ event: AgentNeedsInputEvent) throws -> AgentNeedsInputPublishResult {
        guard !event.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !event.surfaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .targetUnavailable
        }

        if isDuplicate(event) {
            return .duplicateSuppressed
        }

        let statusValue = String.localizedStringWithFormat(
            String(localized: "agent.generic.notification.status.needsInput", defaultValue: "%@ needs input"),
            event.title
        )
        let redactedSubtitle = redact(event.subtitle)
        let redactedBody = redact(event.body)
        let statusCommand = "set_status \(event.statusKey) \(quote(statusValue)) --icon=bell.fill --color=#4C8DFF --priority=100 --tab=\(event.workspaceId)\(surfaceOption(event.surfaceId))"
        _ = try? sendCommand(statusCommand)

        let payload = notificationPayload(event.title, redactedSubtitle, redactedBody)
        let response = try sendCommand("notify_target_async \(event.workspaceId) \(event.surfaceId) \(payload)")
        markPublished(event)
        return .published(response: response)
    }

    func isDuplicate(_ event: AgentNeedsInputEvent) -> Bool {
        guard let sessionId = normalized(event.sessionId),
              let dedupKey = normalized(event.dedupKey) else {
            return false
        }
        do {
            return try sessionStore.recentlyEmittedNotification(
                sessionId: sessionId,
                fingerprint: dedupKey,
                within: dedupInterval
            )
        } catch {
            recordPersistenceError("dedup-read", error)
            return false
        }
    }

    func markPublished(_ event: AgentNeedsInputEvent) {
        guard let sessionId = normalized(event.sessionId),
              let dedupKey = normalized(event.dedupKey) else {
            return
        }
        do {
            try sessionStore.markNotificationEmitted(
                sessionId: sessionId,
                fingerprint: dedupKey,
                marksAskUserQuestion: event.sourceSignal == .claudeAskUserQuestion
            )
        } catch {
            recordPersistenceError("dedup-write", error)
        }
    }

    static func dedupKey(agentKind: String, sessionId: String?, body: String) -> String? {
        guard let sessionId = normalized(sessionId) else { return nil }
        let bodyFingerprint = normalizedSingleLineForNeedsInput(body).lowercased()
        guard !bodyFingerprint.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(bodyFingerprint.utf8))
        return "needs-input:\(agentKind):\(sessionId):\(lowercaseHexString(for: digest))"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }

    private static func normalizedSingleLineForNeedsInput(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lowercaseHexString<Bytes: Sequence>(for bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(64)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }
}
