import CmuxAuthRuntime
import Foundation

/// Credential-free durable representation of one logical source event.
struct PhonePushRequestEnvelope: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    private static let maximumTitleUTF16Units = 120
    private static let maximumSubtitleUTF16Units = 120
    private static let maximumBodyUTF16Units = 500
    private static let maximumIdentifierUTF16Units = 200
    private static let maximumRequestBytes = 8 * 1024

    private enum EncodingError: Error {
        case identifierTooLong
        case requestTooLarge
    }

    let correlationID: String
    let expirationEpochSeconds: Int
    let body: Data
    let coalescingID: String?
    let expectedAccountID: String?
    let expectedSessionGeneration: UInt64?
    /// Exact iOS bundle identifier selected when this event was queued.
    let targetBundleIdentifier: String?

    init(
        correlationID: String,
        expirationEpochSeconds: Int,
        body: Data,
        coalescingID: String? = nil,
        expectedAccountID: String? = nil,
        expectedSessionGeneration: UInt64? = nil,
        targetBundleIdentifier: String? = nil
    ) {
        self.correlationID = correlationID.lowercased()
        self.expirationEpochSeconds = expirationEpochSeconds
        self.body = body
        self.coalescingID = coalescingID
        self.expectedAccountID = expectedAccountID
        self.expectedSessionGeneration = expectedSessionGeneration
        self.targetBundleIdentifier = targetBundleIdentifier
    }

    init(
        payload: PhonePushPayload,
        correlationID: UUID = UUID(),
        expirationEpochSeconds: Int,
        expectedAccountID: String? = nil,
        expectedSessionGeneration: UInt64? = nil,
        targetBundleIdentifier: String? = nil
    ) throws {
        let canonicalCorrelation = correlationID.uuidString.lowercased()
        let normalizedNotificationID = payload.kind == .notify
            ? try Self.boundedIdentifier(payload.notificationId)
            : nil
        var object: [String: Any] = [
            "kind": payload.kind.rawValue,
            "badgeCount": payload.badgeCount,
            "hideContent": payload.hideContent,
            "correlationId": canonicalCorrelation,
            "expirationEpochSeconds": expirationEpochSeconds,
        ]
        switch payload.kind {
        case .notify:
            object["title"] = payload.hideContent
                ? "cmux"
                : Self.boundedText(
                    payload.title,
                    maximumUTF16Units: Self.maximumTitleUTF16Units
                )
            object["subtitle"] = payload.hideContent
                ? ""
                : Self.boundedText(
                    payload.subtitle,
                    maximumUTF16Units: Self.maximumSubtitleUTF16Units
                )
            object["body"] = payload.hideContent
                ? String(
                    localized: "push.hidden.body",
                    defaultValue: "New terminal activity"
                )
                : Self.boundedText(
                    payload.body,
                    maximumUTF16Units: Self.maximumBodyUTF16Units
                )
            object["retargetsToLiveSurfaceOwner"] =
                payload.retargetsToLiveSurfaceOwner
            // Reply shape is a schema enum, not content: safe under hideContent.
            object["replyShape"] = payload.replyShape
            if let value = try Self.boundedIdentifier(payload.workspaceId) {
                object["workspaceId"] = value
            }
            if let value = try Self.boundedIdentifier(payload.surfaceId) {
                object["surfaceId"] = value
            }
            if let value = try Self.boundedIdentifier(payload.macDeviceId) {
                object["macDeviceId"] = value
            }
            if let normalizedNotificationID {
                object["notificationId"] = normalizedNotificationID
            }
        case .dismiss:
            object["title"] = ""
            object["body"] = ""
            object["notificationIds"] = try payload.notificationIds.map {
                guard let bounded = try Self.boundedIdentifier($0) else {
                    throw EncodingError.identifierTooLong
                }
                return bounded
            }
        }
        let encoded = try JSONSerialization.data(withJSONObject: object)
        guard encoded.count <= Self.maximumRequestBytes else {
            throw EncodingError.requestTooLarge
        }
        self.init(
            correlationID: canonicalCorrelation,
            expirationEpochSeconds: expirationEpochSeconds,
            body: encoded,
            coalescingID: normalizedNotificationID,
            expectedAccountID: expectedAccountID,
            expectedSessionGeneration: expectedSessionGeneration,
            targetBundleIdentifier: targetBundleIdentifier
        )
    }

    func belongs(to session: AuthenticatedSessionSnapshot) -> Bool {
        guard expectedAccountID == nil
                || expectedAccountID == session.accountID else { return false }
        guard expectedSessionGeneration == nil
                || expectedSessionGeneration == session.generation else {
            return false
        }
        return true
    }

    func rebound(accountID: String, generation: UInt64) -> Self {
        Self(
            correlationID: correlationID,
            expirationEpochSeconds: expirationEpochSeconds,
            body: body,
            coalescingID: coalescingID,
            expectedAccountID: accountID,
            expectedSessionGeneration: generation,
            targetBundleIdentifier: targetBundleIdentifier
        )
    }

    func isExpired(at epochSeconds: Int) -> Bool {
        expirationEpochSeconds <= epochSeconds
    }

    var description: String {
        "PhonePushRequestEnvelope(correlationID: \(correlationID), "
            + "expirationEpochSeconds: \(expirationEpochSeconds), "
            + "body: <redacted>, account: <redacted>)"
    }

    var debugDescription: String { description }

    private static func boundedText(
        _ value: String,
        maximumUTF16Units: Int
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count > maximumUTF16Units else { return trimmed }
        var usedUTF16Units = 0
        return String(trimmed.prefix { character in
            let count = String(character).utf16.count
            guard usedUTF16Units + count <= maximumUTF16Units else {
                return false
            }
            usedUTF16Units += count
            return true
        })
    }

    private static func boundedIdentifier(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf16.count <= maximumIdentifierUTF16Units else {
            throw EncodingError.identifierTooLong
        }
        return trimmed
    }
}
