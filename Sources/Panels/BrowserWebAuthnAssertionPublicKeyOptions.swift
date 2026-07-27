import Foundation

struct BrowserWebAuthnAssertionPublicKeyOptions: Decodable {
    let challenge: BrowserWebAuthnBinaryData
    let rpId: String?
    let allowCredentials: [BrowserWebAuthnCredentialDescriptor]?
    let userVerification: String?
    let extensions: BrowserWebAuthnAssertionExtensions?

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

extension BrowserWebAuthnAssertionPublicKeyOptions {
    func validateNativeRequestShape() throws {
        try challenge.validateByteCount(BrowserWebAuthnRequestParser.challengeByteRange)
        try rpId.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumRelyingPartyIDUTF8Bytes)
        try userVerification.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        let allowedCredentials = allowCredentials ?? []
        guard allowedCredentials.count <= BrowserWebAuthnRequestParser.maximumCredentialDescriptors else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        for descriptor in allowedCredentials {
            try descriptor.validateNativeRequestShape()
        }
        try extensions?.validateNativeRequestShape()
    }
}
