/// A decoded `navigator.credentials.create` request from the WebAuthn bridge.
public struct BrowserWebAuthnCreationRequest: Decodable {
    public let mediation: String?
    public let publicKey: BrowserWebAuthnCreationPublicKeyOptions
}
