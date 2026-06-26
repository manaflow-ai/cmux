/// The user descriptor from a credential-creation request.
public struct BrowserWebAuthnUserDescriptor: Decodable {
    public let id: BrowserWebAuthnBinaryData
    public let name: String?
    public let displayName: String?
}
