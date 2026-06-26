import Foundation

/// The `publicKey` options of a credential-creation request, plus the normalized
/// attestation preference and requested COSE algorithms the ceremony consumes.
public struct BrowserWebAuthnCreationPublicKeyOptions: Decodable {
    public let challenge: BrowserWebAuthnBinaryData
    public let rp: BrowserWebAuthnRelyingPartyDescriptor?
    public let user: BrowserWebAuthnUserDescriptor
    public let pubKeyCredParams: [BrowserWebAuthnCredentialParameter]
    public let excludeCredentials: [BrowserWebAuthnCredentialDescriptor]?
    public let authenticatorSelection: BrowserWebAuthnAuthenticatorSelection?
    public let attestation: String?
}

extension BrowserWebAuthnCreationPublicKeyOptions {
    /// The normalized attestation conveyance preference, defaulting to `none`.
    public var normalizedAttestationPreference: String {
        switch attestation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "direct":
            return "direct"
        case "enterprise":
            return "enterprise"
        case "indirect":
            return "indirect"
        default:
            return "none"
        }
    }

    /// The COSE algorithm identifiers requested for public-key credentials.
    public var requestedAlgorithms: [Int] {
        pubKeyCredParams
            .filter(\.isPublicKeyCredential)
            .map(\.alg)
    }
}
