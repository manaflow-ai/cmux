package import AppKit
import CmuxNextCompat
package import Foundation
package import ImageIO
package import UniformTypeIdentifiers

/// The one way the app decodes icon and picture bytes it did not draw itself (a download, a daemon's
/// blob, an extension's icon): only the named formats, only up to a sane pixel count, with no source
/// kept in ImageIO's cache, and decoded to pixels at the target size where it runs, so the layer that shows the
/// image draws it without a decode. Callers run it off the main thread (a BackgroundWork lane, an
/// `@concurrent` function) and hand the image to the main thread, as Chrome's extension
/// `ImageLoader` decodes on its thread pool and replies to the UI thread
/// (extensions/browser/image_loader.cc).
package nonisolated struct IconAssetDecode {
    package nonisolated init() {}
    /// What the page accepts for an Image (`IMAGE_TYPES` in webviews/src/icon-picker/AssetTab.tsx).
    package static let pickerTypes: Set<String> = [UTType.png, .jpeg, .webP, .gif, .heic].reduce(into: []) { $0.insert($1.identifier) }
    /// What an owner stores (`image/png`, `image/jpeg`, `image/webp`).
    package static let storedTypes: [String: String] = [
        "image/png": UTType.png.identifier, "image/jpeg": UTType.jpeg.identifier, "image/webp": UTType.webP.identifier,
    ]
    /// The bitmaps an icon or a picture may come as (an extension's icon, a frame, a cursor): the
    /// picker's types and the older formats a browser still accepts.
    package static let bitmapTypes: Set<String> = pickerTypes.union([UTType.tiff, .bmp, .ico, .icns].map(\.identifier))
    /// Largest side and pixel count decoded at all: a small file can declare a huge bitmap.
    package static let maxSide = 16_384
    package static let maxPixels = 100_000_000
    /// The most pixels a decode on the main thread may make: its image gate
    /// (``BlockingKind/cpuIntensiveImagePixelBytes`` at 4 bytes a pixel), 256 x 256. A caller that must decode
    /// in the main thread's turn (a menu that opens now, a cursor) passes it as `pixelLimit`, so a larger image
    /// is refused rather than decoded there.
    package static let mainThreadPixels = BlockingKind.cpuIntensiveImagePixelBytes / 4

    /// `data` scaled to at most `maxPixelSize` on its longer side, when it is one of `types`
    /// and its declared size is within ``maxSide`` and `pixelLimit` (``maxPixels`` by default); nil
    /// otherwise. The pixels are decoded here (`kCGImageSourceShouldCacheImmediately`), on the calling
    /// thread, as a checked CPU call, not at the image's first draw.
    package static func thumbnail(_ data: Data, types: Set<String>, maxPixelSize: Int,
                                  pixelLimit: Int = IconAssetDecode.maxPixels) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CheckedImageSource(data, options: options),
              let type = source.type, types.contains(type),
              let properties = source.properties(at: 0, options: options),
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxSide, height <= maxSide, width * height <= min(maxPixels, pixelLimit) else { return nil }
        return source.thumbnail(options: [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ])
    }

    /// `bitmap` (a ``thumbnail(_:types:maxPixelSize:)``) as an image `points` on its longer side,
    /// its aspect kept. It wraps the pixels, so the thread that draws it decodes nothing.
    package static func image(_ bitmap: CGImage, points: CGFloat) -> NSImage {
        let longer = CGFloat(max(bitmap.width, bitmap.height))
        let scale = longer > 0 ? points / longer : 1
        return NSImage(cgImage: bitmap, size: NSSize(width: CGFloat(bitmap.width) * scale, height: CGFloat(bitmap.height) * scale))
    }

    /// Whether `data` looks like SVG text: UTF-8 whose first non-space character is `<` (so a
    /// PDF or EPS labelled as SVG never reaches `NSImage`'s other decoders).
    package static func isSVGText(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(1024), encoding: .utf8) ?? String(data: data, encoding: .utf8) else { return false }
        return text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }.first == "<"
    }
}
