import Foundation

struct BrowserWebAuthnCredentialDescriptor: Decodable {
    let type: String?
    let id: BrowserWebAuthnBinaryData
    let transports: [String]?

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
        try type.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try id.validateByteCount(BrowserWebAuthnRequestParser.credentialIDByteRange)
        let credentialTransports = transports ?? []
        guard credentialTransports.count <= BrowserWebAuthnRequestParser.maximumCredentialTransports else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        for transport in credentialTransports {
            try Optional(transport).validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        }
    }
}
