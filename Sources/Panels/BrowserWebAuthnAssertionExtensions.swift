struct BrowserWebAuthnAssertionExtensions: Decodable {
    let appid: String?
}

extension BrowserWebAuthnAssertionExtensions {
    func validateNativeRequestShape() throws {
        try appid.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumAppIDUTF8Bytes)
    }
}
