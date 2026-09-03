public import CoreGraphics
import Foundation
import ImageIO

/// Actor-backed local-image loader shared by the built-in sidebar renderers.
///
/// File access is injected so callers and tests can supply isolated implementations.
/// Reads, validation, decoding, and cache mutation all run away from the main actor.
public actor SidebarStatusIconImageLoader: SidebarStatusIconImageLoading {
    private struct CacheKey: Hashable {
        let path: String
        let metadata: SidebarStatusIconOpenFile.Metadata
    }

    private struct CacheEntry {
        let image: CGImage
        let decodedByteCount: Int
    }

    private static let maxImageBytes = 1_000_000
    private static let maxPixelCount = 4_194_304
    private static let maxDecodedCacheBytes = 32 * 1024 * 1024
    private static let cacheLimit = 64
    private static let allowedExtensions = Set([
        "bmp", "gif", "heic", "icns", "ico", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ])

    private let fileReader: SidebarStatusIconFileReader
    private var images: [CacheKey: CacheEntry] = [:]
    private var insertionOrder: [CacheKey] = []
    private var decodedCacheByteCount = 0

    /// Creates a loader backed by a local descriptor-based file reader.
    ///
    /// - Parameter fileReader: The local file reader used for bounded reads.
    public init(fileReader: SidebarStatusIconFileReader) {
        self.fileReader = fileReader
    }

    /// Loads a bounded raster image from an absolute local path or a path beginning with `~`.
    ///
    /// Images larger than 1 MB encoded or 4,194,304 decoded pixels are rejected.
    ///
    /// - Parameter rawPath: The local image path from an `image:` status icon token.
    /// - Returns: The decoded first frame, or `nil` when validation or decoding fails.
    public func image(at rawPath: String) async -> CGImage? {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        guard (expandedPath as NSString).isAbsolutePath else { return nil }

        let path = (expandedPath as NSString).standardizingPath
        let url = URL(fileURLWithPath: path)
        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()),
              let file = fileReader.openFile(at: path, maximumByteCount: Self.maxImageBytes) else {
            return nil
        }

        let key = CacheKey(path: path, metadata: file.metadata)
        if let cached = images[key] {
            return cached.image
        }

        guard let data = file.data(maximumByteCount: Self.maxImageBytes),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              Self.hasSafeDimensions(width: width.intValue, height: height.intValue),
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              Self.hasSafeDimensions(width: image.width, height: image.height) else {
            return nil
        }

        let decodedByteCount = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !decodedByteCount.overflow,
              decodedByteCount.partialValue <= Self.maxDecodedCacheBytes else {
            return nil
        }
        insert(CacheEntry(image: image, decodedByteCount: decodedByteCount.partialValue), for: key)
        return image
    }

    private static func hasSafeDimensions(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let pixels = width.multipliedReportingOverflow(by: height)
        return !pixels.overflow && pixels.partialValue <= maxPixelCount
    }

    private func insert(_ entry: CacheEntry, for key: CacheKey) {
        images[key] = entry
        insertionOrder.append(key)
        decodedCacheByteCount += entry.decodedByteCount
        while insertionOrder.count > Self.cacheLimit
            || decodedCacheByteCount > Self.maxDecodedCacheBytes {
            let evictedKey = insertionOrder.removeFirst()
            if let evicted = images.removeValue(forKey: evictedKey) {
                decodedCacheByteCount -= evicted.decodedByteCount
            }
        }
    }
}
