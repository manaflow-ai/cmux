package import Foundation
package import ImageIO
package import UniformTypeIdentifiers

/// The one way the app decodes icon asset bytes it did not draw itself (a download, a daemon's
/// blob): only the named formats, only up to a sane pixel count, never cached by ImageIO.
package nonisolated struct IconAssetDecode {
    package nonisolated init() {}
    /// What the page accepts for an Image (`IMAGE_TYPES` in webviews/src/icon-picker/AssetTab.tsx).
    package static let pickerTypes: Set<String> = [UTType.png, .jpeg, .webP, .gif, .heic].reduce(into: []) { $0.insert($1.identifier) }
    /// What an owner stores (`image/png`, `image/jpeg`, `image/webp`).
    package static let storedTypes: [String: String] = [
        "image/png": UTType.png.identifier, "image/jpeg": UTType.jpeg.identifier, "image/webp": UTType.webP.identifier,
    ]
    /// Largest side and pixel count decoded at all: a small file can declare a huge bitmap.
    package static let maxSide = 16_384
    package static let maxPixels = 100_000_000

    /// `data` scaled to at most `maxPixelSize` on its longer side, when it is one of `types`
    /// and its declared size is within ``maxSide`` and ``maxPixels``; nil otherwise.
    package static func thumbnail(_ data: Data, types: Set<String>, maxPixelSize: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String?, types.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxSide, height <= maxSide, width * height <= maxPixels else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    /// Whether `data` looks like SVG text: UTF-8 whose first non-space character is `<` (so a
    /// PDF or EPS labelled as SVG never reaches `NSImage`'s other decoders).
    package static func isSVGText(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(1024), encoding: .utf8) ?? String(data: data, encoding: .utf8) else { return false }
        return text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }.first == "<"
    }
}
