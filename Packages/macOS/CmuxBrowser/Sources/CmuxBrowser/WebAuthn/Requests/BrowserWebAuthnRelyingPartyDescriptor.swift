/// The relying-party (`rp`) descriptor from a credential-creation request.
public struct BrowserWebAuthnRelyingPartyDescriptor: Decodable {
    public let id: String?
    public let name: String?
}
