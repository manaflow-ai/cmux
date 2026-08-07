import Foundation

/// Byte-exact identity for opaque protocol strings.
///
/// Swift `String` equality uses Unicode canonical equivalence, while provider
/// identifiers and protocol tokens are opaque UTF-8 values. This wrapper keeps
/// those representations distinct without changing their public string APIs.
/// Its wire form is prefixed, versioned base64 so Foundation never interprets
/// a leading U+FEFF as a byte-order mark while decoding a JSON string.
struct ExactUTF8String: Codable, Comparable, Hashable, Sendable {
    private static let codingPrefix = "cmux-utf8-v1:"

    let value: String

    init(_ value: String) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard encoded.hasPrefix(Self.codingPrefix) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Missing exact UTF-8 encoding prefix"
            )
        }

        let payload = String(encoded.dropFirst(Self.codingPrefix.count))
        guard let bytes = Data(base64Encoded: payload),
              bytes.base64EncodedString() == payload
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid exact UTF-8 base64 payload"
            )
        }

        let value = String(decoding: bytes, as: UTF8.self)
        guard value.utf8.elementsEqual(bytes) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid exact UTF-8 byte sequence"
            )
        }
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let payload = Data(value.utf8).base64EncodedString()
        try container.encode(Self.codingPrefix + payload)
    }

    static func == (lhs: ExactUTF8String, rhs: ExactUTF8String) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    static func < (lhs: ExactUTF8String, rhs: ExactUTF8String) -> Bool {
        lhs.value.utf8.lexicographicallyPrecedes(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value.utf8.count)
        for byte in value.utf8 {
            hasher.combine(byte)
        }
    }
}
