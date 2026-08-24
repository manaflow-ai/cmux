import CryptoKit
import Foundation

/// Errors raised when a plugin artifact cannot be represented safely.
enum CmuxPluginArtifactFingerprintError: Error {
    case missingManifest
    case symbolicLink(URL)
    case unsupportedFile(URL)
    case unreadableFile(URL)
}

/// Computes a deterministic digest for every regular file in a plugin bundle.
///
/// The directory scan is intentionally strict: symbolic links and special
/// files are rejected so the digest cannot omit mutable code reached through a
/// delegated path. Files are hashed independently and then folded into a
/// path-ordered parent digest, which keeps memory bounded for large binaries.
struct CmuxPluginArtifactFingerprinter {
    private static let chunkSize = 64 * 1024
    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)
    private static let formatMarker = Data("cmux-plugin-artifact-v2".utf8)

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fingerprint(
        manifestData: Data,
        pluginDirectoryURL: URL,
        entrypointDeclaration: String
    ) throws -> String {
        let root = pluginDirectoryURL.standardizedFileURL
        let files = try regularFiles(in: root)
        let manifestRelativePath = "manifest.json"
        guard files.contains(where: { $0.relativePath == manifestRelativePath }) else {
            throw CmuxPluginArtifactFingerprintError.missingManifest
        }
        let manifestURL = root.appendingPathComponent(manifestRelativePath, isDirectory: false)
        let currentManifestData: Data
        do {
            currentManifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw CmuxPluginArtifactFingerprintError.unreadableFile(manifestURL)
        }
        guard currentManifestData == manifestData else {
            throw CmuxPluginArtifactFingerprintError.unreadableFile(manifestURL)
        }

        var hasher = SHA256()
        hasher.update(data: Self.formatMarker)
        updateLengthPrefixed(Data(entrypointDeclaration.utf8), into: &hasher)

        for file in files {
            updateLengthPrefixed(Data(file.relativePath.utf8), into: &hasher)
            let fileDigest: (byteCount: UInt64, digest: SHA256.Digest)
            if file.relativePath == manifestRelativePath {
                fileDigest = (
                    UInt64(currentManifestData.count),
                    SHA256.hash(data: currentManifestData)
                )
            } else {
                fileDigest = try digestFile(at: file.url)
            }
            updateUInt64(fileDigest.byteCount, into: &hasher)
            hasher.update(data: Data(fileDigest.digest))
        }

        return hexadecimalString(for: hasher.finalize())
    }

    private func regularFiles(
        in root: URL
    ) throws -> [(relativePath: String, url: URL)] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw CmuxPluginArtifactFingerprintError.unreadableFile(root)
        }

        var files: [(relativePath: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                throw CmuxPluginArtifactFingerprintError.unreadableFile(url)
            }
            guard values.isSymbolicLink != true else {
                throw CmuxPluginArtifactFingerprintError.symbolicLink(url)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw CmuxPluginArtifactFingerprintError.unsupportedFile(url)
            }
            guard url.path.hasPrefix(root.path + "/") else {
                throw CmuxPluginArtifactFingerprintError.symbolicLink(url)
            }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            files.append((relativePath: relativePath, url: url))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func digestFile(at url: URL) throws -> (byteCount: UInt64, digest: SHA256.Digest) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CmuxPluginArtifactFingerprintError.unreadableFile(url)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount: UInt64 = 0
        do {
            while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                byteCount += UInt64(chunk.count)
                hasher.update(data: chunk)
            }
        } catch {
            throw CmuxPluginArtifactFingerprintError.unreadableFile(url)
        }
        return (byteCount, hasher.finalize())
    }

    private func updateLengthPrefixed(
        _ data: Data,
        into hasher: inout SHA256
    ) {
        updateUInt64(UInt64(data.count), into: &hasher)
        hasher.update(data: data)
    }

    private func updateUInt64(
        _ value: UInt64,
        into hasher: inout SHA256
    ) {
        let bigEndianValue = value.bigEndian
        let data = withUnsafeBytes(of: bigEndianValue) { Data($0) }
        hasher.update(data: data)
    }

    private func hexadecimalString(for digest: SHA256.Digest) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            bytes.append(Self.lowercaseHexDigits[Int(byte >> 4)])
            bytes.append(Self.lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
