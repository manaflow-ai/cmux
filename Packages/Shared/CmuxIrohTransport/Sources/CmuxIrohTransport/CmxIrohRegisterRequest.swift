/// Signed second leg of endpoint registration.
public struct CmxIrohRegisterRequest: Encodable, Equatable, Sendable {
    /// One-use challenge UUID.
    public let challengeId: String
    /// Broker nonce copied verbatim from the challenge.
    public let nonce: String
    /// Base64url-encoded canonical payload bytes.
    public let payload: String
    /// Base64url Ed25519 signature over the registration transcript.
    public let signature: String

    init(challengeID: String, nonce: String, payload: String, signature: String) {
        challengeId = challengeID
        self.nonce = nonce
        self.payload = payload
        self.signature = signature
    }
}
