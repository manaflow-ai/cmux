import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Streaming sha256 of an open descriptor, as lowercase hex.
struct FileDigest {
    static let blockBytes = 1 << 20

    let descriptor: Int32

    /// Hashes `length` bytes from offset 0 with `pread`, so the descriptor's
    /// position is untouched. Nil on a read error or a short file.
    func sha256(length: UInt64) -> String? {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.blockBytes)
        var offset: UInt64 = 0
        while offset < length {
            let want = Int(min(UInt64(Self.blockBytes), length - offset))
            let got = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, want, off_t(offset)) }
            guard got > 0 else { return nil }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<got])) }
            offset += UInt64(got)
        }
        return hasher.finalize().hex
    }

    static func isValidHex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hex(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).hex
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
