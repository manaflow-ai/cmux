public import CmuxAuthRuntime
public import Foundation

/// A credential-free durable representation of one logical source event.
public struct PhonePushRequestEnvelope: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    private static let maximumTitleUTF16Units = 120
    private static let maximumSubtitleUTF16Units = 120
    private static let maximumBodyUTF16Units = 500
    private static let maximumIdentifierUTF16Units = 200
    public static let maximumEncryptedPayloads = 200
    public static let maximumRequestBytes = 1024 * 1024

    public enum EncodingError: Error, Equatable {
        case identifierTooLong
        case requestTooLarge
        case tooManyEncryptedPayloads
    }

    /// A lowercase identifier shared by retries of the same request.
    public let correlationID: String
    /// The latest epoch second at which the request may be delivered.
    public let expirationEpochSeconds: Int
    /// The encoded API request body.
    public let body: Data
    /// The identifier used to supersede an older notification event.
    public let coalescingID: String?
    /// The account that owned the request when it was created.
    public let expectedAccountID: String?
    /// The authentication generation that owned the request when it was created.
    public let expectedSessionGeneration: UInt64?
    /// Optional exact iOS bundle identifier for a legacy single-lane request.
    /// New requests omit this field and fan out to every encrypted recipient.
    public let targetBundleIdentifier: String?

    /// Restores an already encoded request from durable storage.
    public init(
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

    /// Validates and encodes a request payload for delivery.
    public init(
        payload: PhonePushPayload,
        correlationID: UUID = UUID(),
        expirationEpochSeconds: Int,
        expectedAccountID: String? = nil,
        expectedSessionGeneration: UInt64? = nil,
        targetBundleIdentifier: String? = nil,
        macPushPublicKey: String? = nil,
        macInstallationID: String? = nil,
        macBuildID: String? = nil
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
        if let macPushPublicKey { object["macPushPublicKey"] = macPushPublicKey }
        if let macInstallationID { object["macInstallationID"] = macInstallationID }
        if let macBuildID { object["macBuildID"] = macBuildID }
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
            object["replyShape"] = payload.replyShape
            object["category"] = payload.replyShape == "text"
                ? "cmux.terminal.reply"
                : "cmux.terminal"
            if let value = try Self.boundedIdentifier(payload.workspaceId) {
                object["workspaceId"] = value
            }
            if let value = try Self.boundedIdentifier(payload.surfaceId) {
                object["surfaceId"] = value
            }
            if let value = try Self.boundedIdentifier(payload.macDeviceId) {
                object["macDeviceId"] = value
            }
            if let value = try Self.boundedIdentifier(payload.macInstanceTag) {
                object["macInstanceTag"] = value
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

    /// Builds the server request from ciphertext only. The logical payload is
    /// never persisted in this envelope or sent to the web service.
    public init(
        encryptedPayloads: [PhonePushEncryptedPayload],
        payload: PhonePushPayload,
        correlationID: UUID = UUID(),
        expirationEpochSeconds: Int,
        expectedAccountID: String? = nil,
        expectedSessionGeneration: UInt64? = nil,
        targetBundleIdentifier: String? = nil
    ) throws {
        guard !encryptedPayloads.isEmpty else { throw EncodingError.requestTooLarge }
        guard encryptedPayloads.count <= Self.maximumEncryptedPayloads else {
            throw EncodingError.tooManyEncryptedPayloads
        }
        let canonicalCorrelation = correlationID.uuidString.lowercased()
        let normalizedNotificationID = payload.kind == .notify
            ? try Self.boundedIdentifier(payload.notificationId)
            : nil
        var object: [String: Any] = [
            "kind": payload.kind.rawValue,
            "badgeCount": payload.badgeCount,
            "replyShape": payload.replyShape,
            "correlationId": canonicalCorrelation,
            "expirationEpochSeconds": expirationEpochSeconds,
            "encryptedPayloads": try encryptedPayloads.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
        ]
        if let macDeviceId = payload.macDeviceId { object["macDeviceId"] = macDeviceId }
        if let macInstanceTag = payload.macInstanceTag { object["macInstanceTag"] = macInstanceTag }
        if let normalizedNotificationID {
            object["notificationId"] = normalizedNotificationID
        }
        let encoded = try JSONSerialization.data(withJSONObject: object)
        guard encoded.count <= Self.maximumRequestBytes else { throw EncodingError.requestTooLarge }
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

    /// Returns whether the authenticated session still owns the request.
    public func belongs(to session: AuthenticatedSessionSnapshot) -> Bool {
        guard expectedAccountID == nil
                || expectedAccountID == session.accountID else { return false }
        guard expectedSessionGeneration == nil
                || expectedSessionGeneration == session.generation else {
            return false
        }
        return true
    }

    /// Returns a copy owned by the supplied authenticated session.
    public func rebound(accountID: String, generation: UInt64) -> Self {
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

    /// Returns whether the request is no longer eligible for delivery.
    public func isExpired(at epochSeconds: Int) -> Bool {
        expirationEpochSeconds <= epochSeconds
    }

    /// A redacted diagnostic description that excludes credentials and payload.
    public var description: String {
        "PhonePushRequestEnvelope(correlationID: \(correlationID), "
            + "expirationEpochSeconds: \(expirationEpochSeconds), "
            + "body: <redacted>, account: <redacted>)"
    }

    /// A redacted diagnostic description that excludes credentials and payload.
    public var debugDescription: String { description }

    private static func boundedText(
        _ value: String,
        maximumUTF16Units: Int
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count > maximumUTF16Units else { return trimmed }
        var bounded = String()
        var consumedUnits = 0
        for character in trimmed {
            let characterUnits = String(character).utf16.count
            guard consumedUnits + characterUnits <= maximumUTF16Units else { break }
            bounded.append(character)
            consumedUnits += characterUnits
        }
        return bounded
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
