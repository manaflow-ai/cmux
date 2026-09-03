// Relay connect authentication (v2): the endpoint presents its OWN Stack
// access token on the WebSocket upgrade; the relay worker verifies it against
// the Stack API and derives the object name from the verified user id. There
// is no ticket and no web-app mint. The provider must return a token that is
// fresh by the caller's own auth stack (both platforms' providers refresh on
// demand), so a stale token here means the session is genuinely dying.

import CMUXMobileCore
import Foundation

/// The endpoint's current Stack access token. Throws when signed out.
public typealias RelayAccessTokenProvider = @Sendable () async throws -> String

public enum RelayConnectAuth {
    /// Connect headers for one dial. The worker deletes the token header
    /// before forwarding to the Durable Object.
    public static func headers(
        accessToken: String,
        role: RelayRole,
        hostDeviceID: String,
        deviceID: String
    ) -> [String: String] {
        [
            RelayProtocol.stackAccessHeaderName: accessToken,
            RelayProtocol.roleHeaderName: role.rawValue,
            RelayProtocol.hostDeviceHeaderName: hostDeviceID.lowercased(),
            RelayProtocol.deviceHeaderName: deviceID.lowercased(),
        ]
    }

    /// The default production dial target; a Debug env override on either
    /// platform substitutes the dev worker.
    public static func defaultRelayURL() -> URL? {
        URL(string: RelayProtocol.defaultRelayURL)
    }
}

/// The host admits each client session END TO END: the client's first frame
/// on the RPC channel is this request, carrying the same Stack token, and the
/// host verifies it itself (the relay chain is not trusted with data-plane
/// authority). The client sends it fire-and-forget: a rejected admission ends
/// with the host closing the session, which surfaces as EOF and drives the
/// normal repair path. The response id is unknown to the RPC session and is
/// dropped by its dispatch.
public enum RelayAdmission {
    public static let method = "mobile.session.admit"
    public static let requestID = "relay-admit-1"

    /// The admission request as one length-prefixed sync frame, ready to be
    /// the first bytes on a client session's RPC stream.
    public static func admitFrame(accessToken: String, deviceID: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": requestID,
            "method": method,
            "params": ["device_id": deviceID.lowercased()],
            "auth": ["stack_access_token": accessToken],
        ]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        return try MobileSyncFrameCodec.encodeFrame(json)
    }
}
