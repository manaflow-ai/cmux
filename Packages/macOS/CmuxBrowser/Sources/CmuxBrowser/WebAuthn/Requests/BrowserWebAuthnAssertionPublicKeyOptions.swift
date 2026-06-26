import Foundation

/// The `publicKey` options of a credential-assertion request, plus the
/// normalized user-verification preference the ceremony consumes.
public struct BrowserWebAuthnAssertionPublicKeyOptions: Decodable {
    public let challenge: BrowserWebAuthnBinaryData
    public let rpId: String?
    public let allowCredentials: [BrowserWebAuthnCredentialDescriptor]?
    public let userVerification: String?
    public let extensions: BrowserWebAuthnAssertionExtensions?
}

extension BrowserWebAuthnAssertionPublicKeyOptions {
    /// The user-verification preference, defaulting to `preferred`.
    public var normalizedUserVerificationPreference: String {
        switch userVerification?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "required":
            return "required"
        case "discouraged":
            return "discouraged"
        default:
            return "preferred"
        }
    }
}
