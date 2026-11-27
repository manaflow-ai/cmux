struct BrowserWebAuthnCreationRequest: Decodable {
    let mediation: String?
    public let publicKey: BrowserWebAuthnCreationPublicKeyOptions
}

extension BrowserWebAuthnCreationRequest {
    func validateNativeRequestShape() throws {
        try publicKey.validateNativeRequestShape()
    }
}
