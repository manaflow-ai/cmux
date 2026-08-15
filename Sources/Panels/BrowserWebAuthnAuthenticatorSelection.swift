import Foundation

struct BrowserWebAuthnAuthenticatorSelection: Decodable {
    let authenticatorAttachment: String?
    let residentKey: String?
    let requireResidentKey: Bool?
    let userVerification: String?

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

extension BrowserWebAuthnAuthenticatorSelection {
    func validateNativeRequestShape() throws {
        try authenticatorAttachment.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try residentKey.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try userVerification.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
    }
}
