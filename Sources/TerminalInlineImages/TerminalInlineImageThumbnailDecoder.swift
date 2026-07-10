import AppKit
import Foundation
import ImageIO

/// Reads image metadata and produces bounded-size thumbnails for the shared repository.
struct TerminalInlineImageThumbnailDecoder: Sendable {
    nonisolated func metadataKey(for path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value <= 50 * 1024 * 1024 else {
            return nil
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(fileSize.int64Value)|\(modified)"
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    func decode(path: String) async -> TerminalInlineImageThumbnail? {
        guard !Task.isCancelled else { return nil }
        let url = URL(fileURLWithPath: path)
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              !Task.isCancelled else {
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
        ), !Task.isCancelled else {
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
