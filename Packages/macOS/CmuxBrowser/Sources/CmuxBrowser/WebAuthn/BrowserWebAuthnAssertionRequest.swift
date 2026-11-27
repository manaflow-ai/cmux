struct BrowserWebAuthnAssertionRequest: Decodable {
    let mediation: String?
    public let publicKey: BrowserWebAuthnAssertionPublicKeyOptions
}

extension BrowserWebAuthnAssertionRequest {
    func validateNativeRequestShape() throws {
        try publicKey.validateNativeRequestShape()
    }
}
