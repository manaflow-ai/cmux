public import AuthenticationServices
import Foundation

/// A single credential descriptor (`excludeCredentials` / `allowCredentials`
/// entry) from a WebAuthn request, plus its mapping into the
/// AuthenticationServices platform and security-key descriptor types.
public struct BrowserWebAuthnCredentialDescriptor: Decodable {
    public let type: String?
    public let id: BrowserWebAuthnBinaryData
    public let transports: [String]?

    public var normalizedType: String {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "public-key"
    }

    public var normalizedTransports: [BrowserWebAuthnTransport] {
        (transports ?? []).compactMap(BrowserWebAuthnTransport.init(rawValue:))
    }

    public var isPublicKeyCredential: Bool {
        normalizedType == "public-key"
    }
}

extension BrowserWebAuthnCredentialDescriptor {
    /// The platform (passkey) credential descriptor, or nil for non-public-key entries.
    public func platformDescriptor() -> ASAuthorizationPlatformPublicKeyCredentialDescriptor? {
        guard isPublicKeyCredential else { return nil }
        return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: id.data)
    }

    /// The security-key credential descriptor, or nil for non-public-key entries.
    public func securityKeyDescriptor() -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor? {
        guard isPublicKeyCredential else { return nil }

        let transports = normalizedTransports.compactMap { transport -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport? in
            switch transport {
            case .usb:
                return .init(rawValue: "usb")
            case .nfc:
                return .init(rawValue: "nfc")
            case .ble:
                return .init(rawValue: "ble")
            case .hybrid, .internal:
                return nil
            }
        }

        let descriptorTransports: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport]
        if transports.isEmpty {
            descriptorTransports = [
                .init(rawValue: "usb"),
                .init(rawValue: "nfc"),
                .init(rawValue: "ble"),
            ]
        } else {
            descriptorTransports = transports
        }

        return ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
            credentialID: id.data,
            transports: descriptorTransports
        )
    }
}
