import CryptoKit
import Foundation

/// Computes the lowercase hexadecimal SHA-256 digests bound into sudo manifests and helpers.
enum SudoSHA256 {
    static func hex(_ data: Data) -> String {
        hex(digest: Data(SHA256.hash(data: data)))
    }

    static func hex(digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidHex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}
