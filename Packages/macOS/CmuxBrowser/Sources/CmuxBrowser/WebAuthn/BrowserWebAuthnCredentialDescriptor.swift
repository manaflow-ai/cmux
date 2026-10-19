import Foundation

struct BrowserWebAuthnCredentialDescriptor: Decodable {
    public let type: String?
    public let id: BrowserWebAuthnBinaryData
    public let transports: [String]?

    var normalizedType: String {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "public-key"
    }

    var normalizedTransports: [BrowserWebAuthnTransport] {
        (transports ?? []).compactMap(BrowserWebAuthnTransport.init(rawValue:))
    }

    var isPublicKeyCredential: Bool {
        normalizedType == "public-key"
    }
}

extension BrowserWebAuthnCredentialDescriptor {
    func validateNativeRequestShape() throws {
        try id.validateByteCount(BrowserWebAuthnRequestParser.credentialIDByteRange)
    }
}
