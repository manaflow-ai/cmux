import CmuxScreenKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo from the picker, in a form the Mac's pasteboard takes, at its full size, upright in its
/// pixels and with no location in it. A PNG or JPEG that is already upright and has no GPS goes as
/// it is. Anything else (HEIC, a sideways or located photo, …) is decoded by ImageIO with its
/// orientation applied to the pixels (an agent that reads pixels, not the EXIF tag, sees it the
/// right way up), and written as PNG when it has transparency, JPEG otherwise, with orientation 1
/// and no GPS. No UIKit drawing context is made. No size limit: the image goes to the Mac in chunks
/// (``ScreenInput/pasteImageChunks(_:type:id:)``). Builds on macOS too, so its tests run there.
struct PastedImage: Sendable, Equatable {
    let data: Data
    /// The uniform type identifier (`public.png`, `public.jpeg`).
    let type: String

    init(data: Data, type: String) {
        self.data = data
        self.type = type
    }

    /// Nil when `photo` is no image, or cannot be converted.
    init?(photo: Data) {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        self.init(photo: photo, source: source, properties: properties)
    }

    /// `photo` prepared from its `source` and the first image's `properties` as ImageIO read them
    /// (the tests give properties ImageIO seldom reads, such as none for the pixel size).
    init?(photo: Data, source: CGImageSource, properties: [CFString: Any]) {
        let upright = (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        let located = properties[kCGImagePropertyGPSDictionary] != nil
        if upright, !located, let type = Self.passThroughType(of: photo) {
            self.init(data: photo, type: type)
            return
        }
        guard let converted = Self.convert(source, properties: properties) else { return nil }
        self = converted
    }

    /// `public.png` or `public.jpeg` from the file's signature; nil for any other format.
    static func passThroughType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "public.png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "public.jpeg" }
        return nil
    }

    /// The photo's first image, turned upright at its full size and re-encoded with no location:
    /// PNG with transparency, else JPEG.
    private static func convert(_ source: CGImageSource, properties: [CFString: Any]) -> PastedImage? {
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // The full-size "thumbnail" with the transform applies the EXIF orientation to the pixels.
        let upright: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, upright as CFDictionary) else { return nil }
        let transparent = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let type = transparent ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        // Only what the Mac needs: no GPS, no EXIF (its own copy of the place and the camera), orientation 1.
        var written: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let profile = properties[kCGImagePropertyProfileName] { written[kCGImagePropertyProfileName] = profile }
        if !transparent { written[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, written as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PastedImage(data: output as Data, type: type.identifier)
    }
}
