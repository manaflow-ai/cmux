import CryptoKit
import Foundation

/// Incremental SHA-256 with a hex digest.
nonisolated struct SHA256Hasher {
    private var inner = SHA256()

    mutating func update(_ data: Data) {
        inner.update(data: data)
    }

    var hex: String {
        inner.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
