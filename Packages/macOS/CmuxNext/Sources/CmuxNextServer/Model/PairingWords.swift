public import Foundation
import CryptoKit

/// The four fingerprint words of a pending server (plans/cmux-next/server.md
/// 6.2 step 2), the same as `cmux_server_core::pairing::fingerprint_words`:
/// SHA-256 of the 32-byte RFC 7638 thumbprint, the first 44 bits as four
/// 11-bit indexes into the BIP-39 English list (`pairing-words.txt`, a copy of
/// the Rust crate's `bip39-english.txt`).
public nonisolated enum PairingWords {
    /// The 2,048 words, or empty when the resource is missing.
    static let list: [String] = {
        guard let url = Bundle.module.url(forResource: "pairing-words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        return words.count == 2048 ? words : []
    }()

    /// Words for the thumbprint the pairing preview returns (base64url,
    /// no padding). Nil when it does not decode to 32 bytes.
    public static func words(thumbprint: String) -> [String]? {
        guard let bytes = base64URLDecode(thumbprint), bytes.count == 32, list.count == 2048 else { return nil }
        let digest = Array(SHA256.hash(data: bytes))
        let bits = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (0..<4).map { index in list[Int((bits >> (64 - 11 * UInt64(index + 1))) & 0x7FF)] }
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
