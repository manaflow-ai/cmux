struct BrowserWebAuthnUserDescriptor: Decodable {
    let id: BrowserWebAuthnBinaryData
    let name: String?
    let displayName: String?
}

extension BrowserWebAuthnUserDescriptor {
    func validateNativeRequestShape() throws {
        try id.validateByteCount(BrowserWebAuthnRequestParser.userIDByteRange)
        try name.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumDisplayStringUTF8Bytes)
        try displayName.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumDisplayStringUTF8Bytes)
    }
}
