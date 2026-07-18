internal import CryptoKit
internal import Foundation

/// A normalized app identity and its deterministic 128-bit backend namespace.
public struct BackendServiceIdentity: Equatable, Sendable {
    /// The canonical lowercase bundle identifier.
    public let normalizedBundleIdentifier: String

    /// The first 128 bits of SHA-256, encoded as lowercase RFC 4648 base32.
    public let token: String

    /// Creates an identity from a safe ASCII bundle identifier.
    ///
    /// Leading and trailing whitespace and ASCII letter case are normalized
    /// before hashing, so Swift and packaging scripts derive the same value.
    ///
    /// - Parameter bundleIdentifier: The source bundle identifier.
    public init?(bundleIdentifier: String) {
        let normalized = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, Self.isValid(normalized) else { return nil }

        let digest = SHA256.hash(data: Data(normalized.utf8))
        normalizedBundleIdentifier = normalized
        token = Self.encodeBase32(digest.prefix(16))
    }

    private static func isValid(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"):
                true
            default:
                false
            }
        }
    }

    private static func encodeBase32<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var accumulator = 0
        var bitCount = 0
        var encoded: [UInt8] = []
        encoded.reserveCapacity(26)

        for byte in bytes {
            accumulator = (accumulator << 8) | Int(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                encoded.append(alphabet[(accumulator >> bitCount) & 0x1f])
            }
            accumulator &= (1 << bitCount) - 1
        }
        if bitCount > 0 {
            encoded.append(alphabet[(accumulator << (5 - bitCount)) & 0x1f])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
