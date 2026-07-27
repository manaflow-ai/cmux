/// First registration leg that binds a broker nonce to exact endpoint state.
public struct CmxIrohChallengeRequest: Encodable, Equatable, Sendable {
    /// Stable app-generated device UUID.
    public let deviceId: String
    /// Stable app-instance UUID.
    public let appInstanceId: String
    /// Safe build or app-instance tag.
    public let tag: String
    /// Exact Iroh EndpointID that will sign the challenge.
    public let endpointId: String
    /// Endpoint identity generation.
    public let identityGeneration: Int
    /// SHA-256 of the exact base64url-decoded payload bytes.
    public let payloadSha256: String

    init(payload: CmxIrohRegistrationPayload, payloadSHA256: String) {
        deviceId = payload.deviceID
        appInstanceId = payload.appInstanceID
        tag = payload.tag
        endpointId = payload.endpointID
        identityGeneration = payload.identityGeneration
        payloadSha256 = payloadSHA256
    }
}
