import Foundation

/// Shared validation and encoding helpers for the fixed broker wire contract.
///
/// Every rule here mirrors the previous transport byte for byte: the server
/// does not change in this program, so hex, base64url, UUID, token, and relay
/// origin canonicalization must keep accepting and rejecting exactly the same
/// inputs as before.
enum PeerBrokerWire {
    /// The largest managed relay fleet any broker response may describe.
    static let maximumRelayCount = 16

    /// The largest server retry floor honored from a Retry-After header.
    static let maximumRetryAfterSeconds = 24 * 60 * 60

    static func isSafeToken(_ value: String, maximumUTF8ByteCount: Int = 64) -> Bool {
        guard (1 ... maximumUTF8ByteCount).contains(value.utf8.count) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 58, 95].contains(byte)
        }
    }

    static func isSafeClientNamespace(_ value: String) -> Bool {
        isSafeToken(value, maximumUTF8ByteCount: 255)
    }

    static func isSafeHeaderValue(_ value: String) -> Bool {
        (1 ... 16 * 1_024).contains(value.utf8.count)
            && !value.unicodeScalars.contains(
                where: { $0.value < 0x20 || $0.value == 0x7f }
            )
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    /// Accepts only lowercase hyphenated v1-8 UUIDs, the broker's ID form.
    static func isBrokerUUID(_ value: String) -> Bool {
        let bytes = Array(value.lowercased().utf8)
        guard bytes.count == 36,
              bytes[8] == 45,
              bytes[13] == 45,
              bytes[18] == 45,
              bytes[23] == 45,
              (49 ... 56).contains(bytes[14]),
              [56, 57, 97, 98].contains(bytes[19]) else {
            return false
        }
        return bytes.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index)
                ? byte == 45
                : (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    static func isSafeDisplayName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf16.count <= 128
            && !value.unicodeScalars.contains(where: {
                $0.value <= 0x1f || $0.value == 0x7f
            })
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes canonical unpadded base64url and rejects every other spelling.
    static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
                      || (65 ... 90).contains(byte)
                      || (97 ... 122).contains(byte)
                      || byte == 45 || byte == 95
              }) else {
            return nil
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard), base64URL(data) == value else {
            return nil
        }
        return data
    }

    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func decodeISO8601(from decoder: any Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let date = parseISO8601(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 broker date"
            )
        }
        return date
    }

    static func iso8601(epochSeconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        )
    }

    /// Normalizes one managed relay origin, rejecting any non-origin URL.
    static func canonicalRelayOrigin(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              host == host.lowercased(),
              !host.isEmpty,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        components.path = "/"
        return components.string
    }

    /// Accepts only already-canonical relay origins (used for stored fleets).
    static func isCanonicalRelayURL(_ value: String) -> Bool {
        canonicalRelayOrigin(value) == value
    }
}
