import CryptoKit
public import Foundation

/// `https://files.cmux.com/cmux-tui/<commit>/manifest.json`: the digest of
/// every binary the `cmux-tui artifacts` workflow published for one commit.
public struct CmuxTUIManifest: Decodable, Sendable {
    public var sourceCommit: String
    public var binaries: [String: String]

    public static func decode(_ data: Data) throws -> CmuxTUIManifest {
        try JSONDecoder().decode(CmuxTUIManifest.self, from: data)
    }
}

/// SHA-256 of a local file, read in 1 MiB chunks.
public struct SHA256File {
    public init() {}
    public static func hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ file: URL, expected: String) throws {
        let actual = try hex(of: file)
        guard actual == expected.lowercased() else {
            throw RemoteInstallError.checksumMismatch(expected: expected.lowercased(), actual: actual)
        }
    }
}
