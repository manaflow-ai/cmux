import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetched attachment variants on disk, one file per hash and variant, for
/// the Home sources whose owner reads bytes by hash through the daemon (the
/// local owner and the Cloud proxy). An owner has no thumbnail service, so a
/// thumbnail is downsampled here from the image (or the video's poster). The
/// least recently used files go first once the cache holds more than `limit`
/// bytes; the owner keeps every byte, so an evicted file costs one more read.
nonisolated struct HomeAttachmentCache: Sendable {
    let directory: URL
    let limit: Int

    /// A local file holding `variant` of `ref`. `read` writes one variant
    /// (the original, the poster or the preview of `ref.hash`) to a file
    /// atomically; it runs only when the cache does not hold that file.
    func fetch(_ ref: AttachmentRef, variant: AttachmentVariant,
               read: (ConversationAttachmentVariant, URL) async throws -> Void) async throws -> URL {
        switch variant {
        case .original:
            return try await cached(ref.hash, variant: .original, mimeType: ref.mimeType, read: read)
        case .poster:
            guard let poster = ref.poster else { throw HomeRejection.invalid("no_poster") }
            return try await cached(ref.hash, variant: .poster, mimeType: poster.mimeType, read: read)
        case .preview:
            guard let preview = ref.preview else { throw HomeRejection.invalid("no_preview") }
            return try await cached(ref.hash, variant: .preview, mimeType: preview.mimeType, read: read)
        case .thumbnail(let maxPixel):
            let target = directory.appendingPathComponent("\(ref.hash)-thumb-\(maxPixel).jpg")
            if FileManager.default.fileExists(atPath: target.path) { return Self.touched(target) }
            let image: URL
            if ref.mimeType.hasPrefix("image/") {
                image = try await fetch(ref, variant: .original, read: read)
            } else if ref.poster != nil {
                image = try await fetch(ref, variant: .poster, read: read)
            } else {
                throw HomeRejection.invalid("no_thumbnail")
            }
            let data = try Self.thumbnailJPEG(of: image, maxPixel: maxPixel)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            trim(keeping: target)
            return target
        }
    }

    /// The variant's cache file, read from the owner once.
    private func cached(_ hash: String, variant: ConversationAttachmentVariant, mimeType: String,
                        read: (ConversationAttachmentVariant, URL) async throws -> Void) async throws -> URL {
        let suffix = UTType(mimeType: mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
        let target = directory.appendingPathComponent("\(hash)-\(variant.rawValue)\(suffix)")
        if FileManager.default.fileExists(atPath: target.path) { return Self.touched(target) }
        try await read(variant, target)
        trim(keeping: target)
        return target
    }

    /// Marks a cache hit as used now (the eviction order).
    private static func touched(_ url: URL) -> URL {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Removes the least recently used cache files until the cache is under
    /// `limit`, never `kept` (the file a fetch is returning). Partial
    /// downloads are hidden files and are left alone.
    func trim(keeping kept: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles]) else { return }
        var entries = files.compactMap { url -> (url: URL, used: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.used < $1.used }
        let keptPath = kept.standardizedFileURL.path
        for entry in entries where total > limit && entry.url.standardizedFileURL.path != keptPath {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    /// A JPEG whose longer side is at most `maxPixel`, EXIF orientation applied.
    static func thumbnailJPEG(of url: URL, maxPixel: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
              ] as CFDictionary) else { throw HomeRejection.invalid("thumbnail_failed") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HomeRejection.invalid("thumbnail_failed")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HomeRejection.invalid("thumbnail_failed") }
        return data as Data
    }
}
