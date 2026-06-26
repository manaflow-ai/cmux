/// Client extensions accepted on a credential-assertion request (currently only
/// the legacy FIDO `appid` extension).
public struct BrowserWebAuthnAssertionExtensions: Decodable {
    public let appid: String?
}
