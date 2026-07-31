import CmuxAuthRuntime
import Foundation

/// Credential-free durable representation of one logical source event.
struct PhonePushRequestEnvelope: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    let correlationID: String
    let expirationEpochSeconds: Int
    let body: Data
    let coalescingID: String?
    let expectedAccountID: String?
    let expectedSessionGeneration: UInt64?

    init(
        correlationID: String,
        expirationEpochSeconds: Int,
        body: Data,
        coalescingID: String? = nil,
        expectedAccountID: String? = nil,
        expectedSessionGeneration: UInt64? = nil
    ) {
        self.correlationID = correlationID.lowercased()
        self.expirationEpochSeconds = expirationEpochSeconds
        self.body = body
        self.coalescingID = coalescingID
        self.expectedAccountID = expectedAccountID
        self.expectedSessionGeneration = expectedSessionGeneration
    }

    init(
        payload: PhonePushPayload,
        correlationID: UUID = UUID(),
        expirationEpochSeconds: Int,
        expectedAccountID: String? = nil,
        expectedSessionGeneration: UInt64? = nil
    ) throws {
        let canonicalCorrelation = correlationID.uuidString.lowercased()
        var object: [String: Any] = [
            "kind": payload.kind.rawValue,
            "badgeCount": payload.badgeCount,
            "hideContent": payload.hideContent,
            "correlationId": canonicalCorrelation,
            "expirationEpochSeconds": expirationEpochSeconds,
        ]
        switch payload.kind {
        case .notify:
            object["title"] = payload.hideContent ? "cmux" : payload.title
            object["subtitle"] = payload.hideContent ? "" : payload.subtitle
            object["body"] = payload.hideContent
                ? "New terminal activity"
                : payload.body
            object["retargetsToLiveSurfaceOwner"] =
                payload.retargetsToLiveSurfaceOwner
            if let value = payload.workspaceId { object["workspaceId"] = value }
            if let value = payload.surfaceId { object["surfaceId"] = value }
            if let value = payload.macDeviceId { object["macDeviceId"] = value }
            if let value = payload.notificationId {
                object["notificationId"] = value
            }
        case .dismiss:
            object["title"] = ""
            object["body"] = ""
            object["notificationIds"] = payload.notificationIds
        }
        self.init(
            correlationID: canonicalCorrelation,
            expirationEpochSeconds: expirationEpochSeconds,
            body: try JSONSerialization.data(withJSONObject: object),
            coalescingID: payload.kind == .notify
                ? payload.notificationId
                : nil,
            expectedAccountID: expectedAccountID,
            expectedSessionGeneration: expectedSessionGeneration
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
            expectedSessionGeneration: generation
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
}
