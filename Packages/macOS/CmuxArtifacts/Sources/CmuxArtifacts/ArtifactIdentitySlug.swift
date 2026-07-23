import CryptoKit
import Foundation

/// Produces compact, readable folder components without collapsing distinct identities.
struct ArtifactIdentitySlug: Sendable {
    private static let hexadecimalDigits = Array("0123456789abcdef".utf8)

    func value(readableIdentity: String, stableIdentity: String) -> String {
        let digest = SHA256.hash(data: Data(stableIdentity.utf8))
        var suffix: [UInt8] = []
        suffix.reserveCapacity(12)
        for byte in digest.prefix(6) {
            suffix.append(Self.hexadecimalDigits[Int(byte >> 4)])
            suffix.append(Self.hexadecimalDigits[Int(byte & 0x0f)])
        }
        return "\(String(readableIdentity.prefix(16)))-\(String(decoding: suffix, as: UTF8.self))"
    }
}
