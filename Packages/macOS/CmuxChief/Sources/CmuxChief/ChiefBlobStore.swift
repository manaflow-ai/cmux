import CmuxHomeCore
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Attachment bytes under `blobs/<sha256>/data.<ext>`, plus thumbnails made
/// on demand next to them. Writes are atomic (temp file, then move), so a
/// crash never leaves a partial blob under its hash.
struct ChiefBlobStore: Sendable {
    let root: URL

    /// The stored file for `hash`, nil when absent.
    func file(_ hash: String) -> URL? {
        let directory = root.appendingPathComponent(hash, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        guard let name = names.sorted().first(where: { $0.hasPrefix("data") }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Copies `source` in under `hash` after checking its SHA-256. A hash
    /// already stored succeeds without copying.
    @discardableResult
    func store(_ source: URL, hash: String, mimeType: String) throws -> URL {
        if let existing = file(hash) { return existing }
        guard try Self.sha256(ofFile: source) == hash else { throw HomeRejection.invalid("hash_mismatch") }
        let directory = root.appendingPathComponent(hash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
        let target = directory.appendingPathComponent("data\(ext)")
        let temp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: temp)
        do {
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if FileManager.default.fileExists(atPath: target.path) { return target }
            throw error
        }
        return target
    }

    /// A JPEG of `image` whose longer side is at most `maxPixel`, cached
    /// next to the blob of `hash`.
    func thumbnail(of image: URL, hash: String, maxPixel: Int) throws -> URL {
        let target = root.appendingPathComponent(hash, isDirectory: true).appendingPathComponent("thumb-\(maxPixel).jpg")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil) else { throw HomeRejection.invalid("no_thumbnail") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1)
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw HomeRejection.invalid("no_thumbnail")
        }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HomeRejection.invalid("no_thumbnail")
        }
        CGImageDestinationAddImage(destination, thumb, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            throw HomeRejection.invalid("no_thumbnail")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: temp)
            return target
        }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// Lowercase hex SHA-256 of a file, read in chunks.
    static func sha256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
