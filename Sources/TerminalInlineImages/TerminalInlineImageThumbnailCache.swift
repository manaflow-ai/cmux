import AppKit
import Foundation
import ImageIO

struct TerminalInlineImageThumbnail: Sendable {
    let cgImage: CGImage
    let pixelSize: CGSize
    let cost: Int
}

private final class TerminalInlineImageThumbnailBox: NSObject {
    let thumbnail: TerminalInlineImageThumbnail

    init(thumbnail: TerminalInlineImageThumbnail) {
        self.thumbnail = thumbnail
    }
}

// SAFETY: Mutable dictionaries are touched only on `queue`; `NSCache` is thread-safe.
final class TerminalInlineImageThumbnailCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cmux.inline-image-thumbnails", qos: .utility)
    private let cache = NSCache<NSString, TerminalInlineImageThumbnailBox>()
    private var cachedKeyByPath: [String: String] = [:]
    private var cachedPathOrder: [String] = []
    private let maximumCachedPathKeys = 384
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        cache.countLimit = 64
    }

    func thumbnail(
        for path: String,
        completion: @escaping @Sendable (TerminalInlineImageThumbnail?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let thumbnail = self.thumbnailOnQueue(for: path)
            DispatchQueue.main.async {
                completion(thumbnail)
            }
        }
    }

    private func thumbnailOnQueue(for path: String) -> TerminalInlineImageThumbnail? {
        guard let fileKey = fileMetadataKey(for: path) else {
            if let previousKey = cachedKeyByPath[path],
               let cached = cache.object(forKey: previousKey as NSString) {
                return cached.thumbnail
            }
            return nil
        }
        if let cached = cache.object(forKey: fileKey as NSString) {
            rememberCachedKey(fileKey, for: path)
            return cached.thumbnail
        }
        guard let thumbnail = decodeThumbnail(path: path) else { return nil }
        cache.setObject(
            TerminalInlineImageThumbnailBox(thumbnail: thumbnail),
            forKey: fileKey as NSString,
            cost: thumbnail.cost
        )
        rememberCachedKey(fileKey, for: path)
        return thumbnail
    }

    private func rememberCachedKey(_ fileKey: String, for path: String) {
        if cachedKeyByPath[path] == nil {
            cachedPathOrder.append(path)
        }
        cachedKeyByPath[path] = fileKey
        guard cachedPathOrder.count > maximumCachedPathKeys else { return }
        let overflow = cachedPathOrder.count - maximumCachedPathKeys
        for expiredPath in cachedPathOrder.prefix(overflow) {
            cachedKeyByPath.removeValue(forKey: expiredPath)
        }
        cachedPathOrder.removeFirst(overflow)
    }

    private func fileMetadataKey(for path: String) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value <= 50 * 1024 * 1024 else {
            return nil
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(fileSize.int64Value)|\(modified)"
    }

    private func decodeThumbnail(path: String) -> TerminalInlineImageThumbnail? {
        let url = URL(fileURLWithPath: path)
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }
        let bytesPerPixel = 4
        let cost = max(1, cgImage.width * cgImage.height * bytesPerPixel)
        return TerminalInlineImageThumbnail(
            cgImage: cgImage,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            cost: cost
        )
    }
}
