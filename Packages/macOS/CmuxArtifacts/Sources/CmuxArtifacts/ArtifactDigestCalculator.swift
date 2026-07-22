import CryptoKit
import Foundation

/// Computes bounded-file SHA-256 identities for deduplication.
struct ArtifactDigestCalculator: Sendable {
    func digest(url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        let digest = SHA256.hash(data: data)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
