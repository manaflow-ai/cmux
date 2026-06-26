import Foundation

/// The `authenticatorSelection` criteria from a credential-creation request,
/// plus the normalized preference strings the native ceremony consumes.
public struct BrowserWebAuthnAuthenticatorSelection: Decodable {
    public let authenticatorAttachment: String?
    public let residentKey: String?
    public let requireResidentKey: Bool?
    public let userVerification: String?
}

extension BrowserWebAuthnAuthenticatorSelection {
    /// The normalized authenticator-attachment hint (`platform` / `cross-platform`), if any.
    public var attachment: String? {
        authenticatorAttachment?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The user-verification preference, defaulting to `preferred`.
    public var userVerificationPreference: String {
        switch userVerification?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "required":
            return "required"
        case "discouraged":
            return "discouraged"
        default:
            return "preferred"
        }
    }

    /// The resident-key preference, falling back to `requireResidentKey`.
    public var residentKeyPreference: String {
        switch residentKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "required":
            return "required"
        case "preferred":
            return "preferred"
        case "discouraged":
            return "discouraged"
        default:
            return requireResidentKey == true ? "required" : "discouraged"
        }
    }
}
