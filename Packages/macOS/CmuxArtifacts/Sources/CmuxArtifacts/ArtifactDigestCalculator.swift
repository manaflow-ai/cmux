import CryptoKit
import Foundation

/// Computes bounded-file SHA-256 identities for deduplication.
struct ArtifactDigestCalculator: Sendable {
    func digest(url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
