struct BrowserWebAuthnUserDescriptor: Decodable {
    public let id: BrowserWebAuthnBinaryData
    public let name: String?
    public let displayName: String?
}

extension BrowserWebAuthnUserDescriptor {
    func validateNativeRequestShape() throws {
        try id.validateByteCount(BrowserWebAuthnRequestParser.userIDByteRange)
        try name.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumDisplayStringUTF8Bytes)
        try displayName.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumDisplayStringUTF8Bytes)
    }
}
