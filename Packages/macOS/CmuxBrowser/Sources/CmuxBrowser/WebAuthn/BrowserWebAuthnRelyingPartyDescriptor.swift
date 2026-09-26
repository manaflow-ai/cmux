struct BrowserWebAuthnRelyingPartyDescriptor: Decodable {
    public let id: String?
    public let name: String?
}

extension BrowserWebAuthnRelyingPartyDescriptor {
    func validateNativeRequestShape() throws {
        try id.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumRelyingPartyIDUTF8Bytes)
        try name.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumDisplayStringUTF8Bytes)
    }
}
