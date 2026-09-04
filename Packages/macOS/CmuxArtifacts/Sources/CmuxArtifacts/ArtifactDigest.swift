import CryptoKit
import Foundation

/// Computes deterministic SHA-256 digests for bounded file payloads.
struct ArtifactDigest {
    let fileManager: FileManager

    func digest(data: Data) -> String {
        SHA256.hash(data: data)
            .map { byte in
                String(byte >> 4, radix: 16) + String(byte & 0x0F, radix: 16)
            }
            .joined()
    }

    func digest(url: URL, maximumBytes: Int64) throws -> (digest: String, data: Data) {
        let data = try ArtifactByteReader(fileManager: fileManager).data(at: url, maximumBytes: maximumBytes)
        return (digest(data: data), data)
    }
}
