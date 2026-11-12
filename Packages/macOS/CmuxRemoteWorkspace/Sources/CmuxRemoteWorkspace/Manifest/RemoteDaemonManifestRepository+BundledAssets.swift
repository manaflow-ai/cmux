internal import CmuxCore
internal import CryptoKit
internal import Foundation

extension RemoteDaemonManifestRepository {
    /// Unpublished dogfood apps carry sealed, compressed daemon resources. Install
    /// one platform into the normal cache without contacting an unpublished URL.
    func installBundledBinary(entry: WorkspaceRemoteDaemonManifest.Entry, version: String) throws -> URL? {
        guard let bundledAssetsDirectory,
              fileManager.fileExists(atPath: bundledAssetsDirectory.path) else { return nil }
        guard !entry.assetName.isEmpty,
              entry.assetName != ".", entry.assetName != "..",
              !entry.assetName.contains("/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let resource = bundledAssetsDirectory.appendingPathComponent(entry.assetName + ".deflate")
        let compressed = try Data(contentsOf: resource)
        let binary = try (compressed as NSData).decompressed(using: .zlib) as Data
        let hex = Array("0123456789abcdef")
        let checksum = String(SHA256.hash(data: binary).flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] })
        guard !binary.isEmpty, checksum == entry.sha256.lowercased() else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let cacheURL = try cachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        let directory = cacheURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".cmuxd-remote-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try binary.write(to: staging, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        do {
            try fileManager.moveItem(at: staging, to: cacheURL)
        } catch {
            // Another workspace may install the same version concurrently.
            guard try validatedCachedBinary(entry: entry, version: version) != nil else { throw error }
        }
        return cacheURL
    }
}
