#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds an orientation-correct transfer copy without decoding a full-resolution bitmap.
package enum AttachmentImageEncoder {
    package static let maxPixelSize = 2048
    package static let jpegQuality: CGFloat = 0.82

    package static func encode(_ data: Data, allowLargerCopy: Bool = false) -> (data: Data, ext: String)? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let typeIdentifier = CGImageSourceGetType(source) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        // A GIF or APNG must retain all frames. Multi-image HEIC/Burst files can
        // still use their first frame as a compact transfer representation.
        if frameCount != 1,
           typeIdentifier as String == UTType.gif.identifier ||
           typeIdentifier as String == UTType.png.identifier {
            return nil
        }
        if typeIdentifier as String == UTType.png.identifier,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) <= maxPixelSize {
            return nil
        }

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            hasAlpha = true
        default:
            hasAlpha = false
        }
        let type: CFString = hasAlpha ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if !hasAlpha { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let optimized = output as Data
        guard optimized.count < data.count || allowLargerCopy else { return nil }
        return (optimized, hasAlpha ? "png" : "jpg")
    }
}
#endif
