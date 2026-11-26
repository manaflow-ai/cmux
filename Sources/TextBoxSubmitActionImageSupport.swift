import AppKit
import Foundation
import ImageIO

enum TextBoxSubmitActionImageSupport {
    static let iconSize: CGFloat = 16
    static let maximumCachedImageCount = 32

    private static let maximumImageBytes = 2 * 1024 * 1024
    private static let maximumSourcePixelCount = 16_777_216

    private static var nsIconSize: NSSize {
        NSSize(width: iconSize, height: iconSize)
    }

    static func imageData(atPath path: String) -> Data? {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumImageBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func image(atPath path: String) -> NSImage? {
        guard let data = imageData(atPath: path) else { return nil }
        return downsampledImage(data: data)
    }

    static func downsampledImage(data: Data) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              width <= maximumSourcePixelCount / height else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(iconSize)
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return NSImage(cgImage: image, size: nsIconSize)
    }

    static func fixedSizeImage(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = nsIconSize
        return copy
    }
}
