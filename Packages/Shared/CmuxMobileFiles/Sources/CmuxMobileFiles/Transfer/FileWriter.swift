import CryptoKit
import Foundation

/// Writes a download's part file at offsets and hashes it at the end.
final class FileWriter: Sendable {
    let url: URL
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw MobileClientError(code: "files.dest_invalid", message: "the download could not be created")
            }
        }
        handle = try FileHandle(forUpdating: url)
    }

    deinit {
        try? handle.close()
    }

    var length: UInt64 { (try? handle.seekToEnd()) ?? 0 }

    func truncate() throws {
        try handle.truncate(atOffset: 0)
    }

    func write(_ data: Data, at offset: UInt64) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    func sha256() throws -> String {
        try handle.synchronize()
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
