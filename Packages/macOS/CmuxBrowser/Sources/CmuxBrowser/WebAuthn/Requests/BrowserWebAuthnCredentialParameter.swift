public import AuthenticationServices
import Foundation

/// A requested public-key credential parameter (`pubKeyCredParams` entry) and
/// its mapping into the AuthenticationServices security-key parameter type.
public struct BrowserWebAuthnCredentialParameter: Decodable {
    public let type: String?
    public let alg: Int

    public var normalizedType: String {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "public-key"
    }

    public var isPublicKeyCredential: Bool {
        normalizedType == "public-key"
    }
}

extension BrowserWebAuthnCredentialParameter {
    /// The security-key credential parameter, or nil for non-public-key entries.
    public func securityKeyCredentialParameter() -> ASAuthorizationPublicKeyCredentialParameters? {
        guard isPublicKeyCredential else { return nil }
        return ASAuthorizationPublicKeyCredentialParameters(
            algorithm: ASCOSEAlgorithmIdentifier(alg)
        )
    }
}
