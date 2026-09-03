public import AppKit
import Foundation

/// Bounded local-image loader shared by the built-in sidebar renderers.
///
/// The cache key includes file metadata so replacing an image in place is
/// picked up the next time its status row is configured.
@MainActor
public enum SidebarStatusIconImageLoader {
    private static let maxImageBytes = 1_000_000
    private static let cacheLimit = 64
    private static let allowedExtensions = Set([
        "bmp", "gif", "heic", "icns", "ico", "jpeg", "jpg", "pdf", "png", "tif", "tiff", "webp",
    ])

    private struct CacheKey: Hashable {
        let path: String
        let fileSize: Int
        let modificationDate: Date
    }

    private static var images: [CacheKey: NSImage] = [:]
    private static var insertionOrder: [CacheKey] = []

    /// Loads an absolute local path or a path beginning with `~`.
    public static func image(at rawPath: String) -> NSImage? {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        guard (expandedPath as NSString).isAbsolutePath else { return nil }

        let path = (expandedPath as NSString).standardizingPath
        let url = URL(fileURLWithPath: path)
        guard allowedExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .fileSizeKey,
                  .contentModificationDateKey,
              ]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maxImageBytes,
              let modificationDate = values.contentModificationDate else {
            return nil
        }

        let key = CacheKey(path: path, fileSize: fileSize, modificationDate: modificationDate)
        if let cached = images[key] {
            return cached
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxImageBytes,
              let image = NSImage(data: data) else {
            return nil
        }
        image.isTemplate = false
        images[key] = image
        insertionOrder.append(key)
        while insertionOrder.count > cacheLimit {
            images.removeValue(forKey: insertionOrder.removeFirst())
        }
        return image
    }
}
