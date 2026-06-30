import Foundation

/// Computes stable non-cryptographic text hashes for disk baselines.
struct TextHash: Sendable {
    /// Returns a stable hexadecimal FNV-1a hash for text.
    /// - Parameter text: Text to hash.
    /// - Returns: A stable hexadecimal hash string.
    func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        return String(value, radix: 16)
    }
}
