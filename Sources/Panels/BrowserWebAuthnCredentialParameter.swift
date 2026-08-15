import Foundation

struct BrowserWebAuthnCredentialParameter: Decodable {
    let type: String?
    let alg: Int

    var normalizedType: String {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "public-key"
    }

    var isPublicKeyCredential: Bool {
        normalizedType == "public-key"
    }
}

extension BrowserWebAuthnCredentialParameter {
    func validateNativeRequestShape() throws {
        try type.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
    }
}
