import Foundation

struct BrowserWebAuthnCredentialParameter: Decodable {
    public let type: String?
    let alg: Int

    var normalizedType: String {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "public-key"
    }

    var isPublicKeyCredential: Bool {
        normalizedType == "public-key"
    }
}
