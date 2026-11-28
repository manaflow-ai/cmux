import Foundation

struct BrowserWebAuthnAuthenticatorSelection: Decodable {
    public let authenticatorAttachment: String?
    let residentKey: String?
    let requireResidentKey: Bool?
    public let userVerification: String?

    public var attachment: String? {
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
