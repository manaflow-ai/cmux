/// Signed registration request: either the second leg of the two-step
/// challenge flow (`challengeId` present) or a one-round self-contained
/// proof (`issuedAt` present). Optional fields are omitted from the encoded
/// body, so older brokers see the exact historical two-step wire shape.
public struct CmxIrohRegisterRequest: Encodable, Equatable, Sendable {
    /// One-use challenge UUID (two-step flow only).
    public let challengeId: String?
    /// Signed proof timestamp in unix seconds (self-proof flow only).
    public let issuedAt: Int64?
    /// The challenge nonce, or the client-chosen one-use self-proof nonce.
    public let nonce: String
    /// Base64url-encoded canonical payload bytes.
    public let payload: String
    /// Base64url Ed25519 signature over the registration transcript.
    public let signature: String
    /// Optional bounded discovery projection returned with registration.
    public let discoveryScope: CmxConnectivityDiscoveryScope?

    init(
        challengeID: String,
        nonce: String,
        payload: String,
        signature: String,
        discoveryScope: CmxConnectivityDiscoveryScope? = nil
    ) {
        challengeId = challengeID
        issuedAt = nil
        self.nonce = nonce
        self.payload = payload
        self.signature = signature
        self.discoveryScope = discoveryScope
    }

    init(
        issuedAt: Int64,
        nonce: String,
        payload: String,
        signature: String,
        discoveryScope: CmxConnectivityDiscoveryScope? = nil
    ) {
        challengeId = nil
        self.issuedAt = issuedAt
        self.nonce = nonce
        self.payload = payload
        self.signature = signature
        self.discoveryScope = discoveryScope
    }

    func including(discoveryScope: CmxConnectivityDiscoveryScope?) -> Self {
        if let challengeId {
            return Self(
                challengeID: challengeId,
                nonce: nonce,
                payload: payload,
                signature: signature,
                discoveryScope: discoveryScope
            )
        }
        return Self(
            issuedAt: issuedAt ?? 0,
            nonce: nonce,
            payload: payload,
            signature: signature,
            discoveryScope: discoveryScope
        )
    }
}
