import Foundation

struct BrowserWebAuthnBinaryData: Decodable {
    let data: Data

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard encoded.utf8.count <= BrowserWebAuthnRequestParser.maximumInboundBase64URLCharacters,
              encoded.utf8.allSatisfy(\.isWebAuthnBase64URLByte) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid base64url-encoded WebAuthn binary value."
            )
        }
        guard let data = Data(base64URLEncoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid base64url-encoded WebAuthn binary value."
            )
        }
        guard data.count <= BrowserWebAuthnRequestParser.maximumInboundBinaryBytes else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "WebAuthn binary value is too large."
            )
        }
        self.data = data
    }
}

extension BrowserWebAuthnBinaryData {
    func validateByteCount(_ range: ClosedRange<Int>) throws {
        guard range.contains(data.count) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
    }
}

private extension Data {
    init?(base64URLEncoded encoded: String) {
        let normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: paddingLength)
        self.init(base64Encoded: padded)
    }
}

private extension UInt8 {
    var isWebAuthnBase64URLByte: Bool {
        switch self {
        case 65 ... 90, 97 ... 122, 48 ... 57, 45, 95:
            return true
        default:
            return false
        }
    }
}
