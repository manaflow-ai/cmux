import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Attachments on the local conversation owner (`local-attachments-v1`):
/// uploads go to the daemon by SHA-256, and fetched variants land in a
/// cache file per hash and variant. The daemon has no thumbnail service, so
/// a thumbnail is downsampled here from the image (or the video's poster).
nonisolated extension DaemonHomeSource {
    /// `~/Library/Caches/<bundle id>/HomeAttachments`.
    static var defaultAttachmentCache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
            .appendingPathComponent("HomeAttachments", isDirectory: true)
    }

    /// 512 MB: a few hundred photos; the owner keeps every byte, so an
    /// evicted file costs one more read.
    static var defaultAttachmentCacheLimit: Int { 512_000_000 }

    func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        let stored = try await Self.attachmentCall {
            try await ConversationClient(self.requireConnection())
                .uploadAttachment(conversation: file.conversation.rawValue, attachment: HomeCoreMapping.attachment(file.ref),
                                  file: file.fileURL, posterFile: file.posterURL, previewFile: file.previewURL,
                                  progress: file.progress)
        }
        // The owner keeps the first record of a hash: its type, size and derived image win.
        var ref = file.ref
        ref.mimeType = stored.mimeType
        ref.byteCount = stored.byteCount
        let derived = { (image: ConversationDerivedImage) in
            AttachmentDerivedImage(hash: image.hash, mimeType: image.mimeType, byteCount: image.byteCount)
        }
        ref.poster = stored.poster.map(derived)
        ref.preview = stored.preview.map(derived)
        return ref
    }

    func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        switch variant {
        case .original:
            return try await cached(ref, location: location, variant: .original, mimeType: ref.mimeType)
        case .poster:
            guard let poster = ref.poster else { throw HomeRejection.invalid("no_poster") }
            return try await cached(ref, location: location, variant: .poster, mimeType: poster.mimeType)
        case .preview:
            guard let preview = ref.preview else { throw HomeRejection.invalid("no_preview") }
            return try await cached(ref, location: location, variant: .preview, mimeType: preview.mimeType)
        case .thumbnail(let maxPixel):
            let target = attachmentCache.appendingPathComponent("\(ref.hash)-thumb-\(maxPixel).jpg")
            if FileManager.default.fileExists(atPath: target.path) { return Self.touched(target) }
            let image: URL
            if ref.mimeType.hasPrefix("image/") {
                image = try await fetch(ref, at: location, variant: .original)
            } else if ref.poster != nil {
                image = try await fetch(ref, at: location, variant: .poster)
            } else {
                throw HomeRejection.invalid("no_thumbnail")
            }
            let data = try Self.thumbnailJPEG(of: image, maxPixel: maxPixel)
            try Task.checkCancellation()
            try data.write(to: target, options: .atomic)
            trimAttachmentCache(keeping: target)
            return target
        }
    }

    /// The variant's cache file, read from the owner once.
    private func cached(_ ref: AttachmentRef, location: AttachmentLocation, variant: ConversationAttachmentVariant,
                        mimeType: String) async throws -> URL {
        let suffix = UTType(mimeType: mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
        let target = attachmentCache.appendingPathComponent("\(ref.hash)-\(variant.rawValue)\(suffix)")
        if FileManager.default.fileExists(atPath: target.path) { return Self.touched(target) }
        try await Self.attachmentCall {
            try await ConversationClient(self.requireConnection())
                .downloadAttachment(conversation: location.conversation.rawValue, hash: ref.hash, variant: variant, to: target)
        }
        trimAttachmentCache(keeping: target)
        return target
    }

    /// Marks a cache hit as used now (the eviction order).
    private static func touched(_ url: URL) -> URL {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Removes the least recently used cache files until the cache is under
    /// `attachmentCacheLimit`, never `kept` (the file a fetch is returning).
    /// Partial downloads are hidden files and are left alone.
    func trimAttachmentCache(keeping kept: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: attachmentCache, includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles]) else { return }
        var entries = files.compactMap { url -> (url: URL, used: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > attachmentCacheLimit else { return }
        entries.sort { $0.used < $1.used }
        let keptPath = kept.standardizedFileURL.path
        for entry in entries where total > attachmentCacheLimit && entry.url.standardizedFileURL.path != keptPath {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    /// `mapped`, plus a local daemon without attachments as a final refusal.
    private static func attachmentCall<T>(_ body: () async throws -> T) async throws -> T {
        try await mapped {
            do {
                return try await body()
            } catch DaemonError.missingCapabilities {
                throw HomeRejection.invalid("attachments_unsupported")
            }
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
