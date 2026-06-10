import AppKit
import AuthenticationServices
import Bonsplit
import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import WebKit


// MARK: - Mapping Parsed WebAuthn Models to AuthenticationServices Inputs
extension Data {
    init?(base64URLEncoded encoded: String) {
        let normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: paddingLength)
        self.init(base64Encoded: padded)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension BrowserWebAuthnAuthenticatorSelection {
    var attachment: String? {
        authenticatorAttachment?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var userVerificationPreference: String {
        switch userVerification?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "required":
            return "required"
        case "discouraged":
            return "discouraged"
        default:
            return "preferred"
        }
    }

    var residentKeyPreference: String {
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

extension BrowserWebAuthnAssertionPublicKeyOptions {
    var normalizedUserVerificationPreference: String {
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

extension BrowserWebAuthnCreationPublicKeyOptions {
    var normalizedAttestationPreference: String {
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

    var requestedAlgorithms: [Int] {
        pubKeyCredParams
            .filter(\.isPublicKeyCredential)
            .map(\.alg)
    }
}

extension BrowserWebAuthnCredentialDescriptor {
    func platformDescriptor() -> ASAuthorizationPlatformPublicKeyCredentialDescriptor? {
        guard isPublicKeyCredential else { return nil }
        return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: id.data)
    }

    func securityKeyDescriptor() -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor? {
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

extension BrowserWebAuthnCredentialParameter {
    func securityKeyCredentialParameter() -> ASAuthorizationPublicKeyCredentialParameters? {
        guard isPublicKeyCredential else { return nil }
        return ASAuthorizationPublicKeyCredentialParameters(
            algorithm: ASCOSEAlgorithmIdentifier(alg)
        )
    }
}

extension ASAuthorizationPublicKeyCredentialAttachment {
    var browserAttachmentValue: String {
        switch self {
        case .platform:
            return "platform"
        case .crossPlatform:
            return "cross-platform"
        @unknown default:
            return "cross-platform"
        }
    }
}

