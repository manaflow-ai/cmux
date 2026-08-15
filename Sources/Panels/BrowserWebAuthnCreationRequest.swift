struct BrowserWebAuthnCreationRequest: Decodable {
    let mediation: String?
    let publicKey: BrowserWebAuthnCreationPublicKeyOptions
}

extension BrowserWebAuthnCreationRequest {
    func validateNativeRequestShape() throws {
        try mediation.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try publicKey.validateNativeRequestShape()
    }
}
