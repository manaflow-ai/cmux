import CryptoKit
import Foundation

/// sha256 of a local file, streamed, as lowercase hex.
public struct LocalFileDigest: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func sha256() throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
