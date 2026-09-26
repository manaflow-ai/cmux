struct BrowserWebAuthnAssertionRequest: Decodable {
    let mediation: String?
    public let publicKey: BrowserWebAuthnAssertionPublicKeyOptions
}

extension BrowserWebAuthnAssertionRequest {
    func validateNativeRequestShape() throws {
        try mediation.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try publicKey.validateNativeRequestShape()
    }
}
