import Foundation

struct BrowserWebAuthnCreationPublicKeyOptions: Decodable {
    let challenge: BrowserWebAuthnBinaryData
    let rp: BrowserWebAuthnRelyingPartyDescriptor?
    let user: BrowserWebAuthnUserDescriptor
    let pubKeyCredParams: [BrowserWebAuthnCredentialParameter]
    let excludeCredentials: [BrowserWebAuthnCredentialDescriptor]?
    let authenticatorSelection: BrowserWebAuthnAuthenticatorSelection?
    let attestation: String?

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

extension BrowserWebAuthnCreationPublicKeyOptions {
    func validateNativeRequestShape() throws {
        try challenge.validateByteCount(BrowserWebAuthnRequestParser.challengeByteRange)
        try rp?.validateNativeRequestShape()
        try user.validateNativeRequestShape()
        guard pubKeyCredParams.count <= BrowserWebAuthnRequestParser.maximumCredentialParameters else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        for parameter in pubKeyCredParams {
            try parameter.validateNativeRequestShape()
        }

        let excludedCredentials = excludeCredentials ?? []
        guard excludedCredentials.count <= BrowserWebAuthnRequestParser.maximumCredentialDescriptors else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        for descriptor in excludedCredentials {
            try descriptor.validateNativeRequestShape()
        }

        try authenticatorSelection?.validateNativeRequestShape()
        try attestation.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
    }
}
