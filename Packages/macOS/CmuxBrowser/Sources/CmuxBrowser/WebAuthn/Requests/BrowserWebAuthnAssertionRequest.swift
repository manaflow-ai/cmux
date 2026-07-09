/// A decoded `navigator.credentials.get` request from the WebAuthn bridge.
public struct BrowserWebAuthnAssertionRequest: Decodable {
    public let mediation: String?
    public let publicKey: BrowserWebAuthnAssertionPublicKeyOptions
}
