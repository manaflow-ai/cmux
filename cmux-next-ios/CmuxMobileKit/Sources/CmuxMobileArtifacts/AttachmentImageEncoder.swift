#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO
import CmuxMobileTransport
import UniformTypeIdentifiers

/// Builds an orientation-correct transfer copy without decoding a full-resolution bitmap.
package struct AttachmentImageEncoder {
    private init() {}
    package static let maxPixelSize = 2048
    package static let jpegQuality: CGFloat = 0.82

    package static func encode(_ data: Data, allowLargerCopy: Bool = false) -> (data: Data, ext: String)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return encode(source: source, originalSize: data.count, allowLargerCopy: allowLargerCopy)
    }

    /// Makes a transfer copy from a picked file while its security scope is open.
    /// Returning nil keeps the URL streamable when the original is already smaller
    /// or when the format must retain all of its frames.
    package static func encode(fileURL: URL, byteCount: Int? = nil,
                               allowLargerCopy: Bool = false) -> (data: Data, ext: String)? {
        ScopedFile(fileURL).withAccess { url in
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
            let originalSize = byteCount ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max)
            return encode(source: source, originalSize: originalSize, allowLargerCopy: allowLargerCopy)
        }
    }

    private static func encode(source: CGImageSource, originalSize: Int,
                               allowLargerCopy: Bool) -> (data: Data, ext: String)? {
        guard let typeIdentifier = CGImageSourceGetType(source) else { return nil }
        let typeName = typeIdentifier as String
        let frameCount = CGImageSourceGetCount(source)
        // A multi-frame image must retain all frames. A thumbnail would silently
        // turn animated WebP, TIFF, GIF, APNG, or a burst into a still image.
        // HEIF bursts are represented as several images, and their first frame is
        // the phone's primary attachment rather than an animation.
        let isHEIF = typeName == UTType.heic.identifier || typeName == UTType.heif.identifier
        guard frameCount == 1 || isHEIF else { return nil }
        if typeName == UTType.png.identifier,
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
        let outputType: CFString = hasAlpha ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if !hasAlpha { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let optimized = output as Data
        guard optimized.count < originalSize || allowLargerCopy else { return nil }
        return (optimized, hasAlpha ? "png" : "jpg")
    }
}
#endif
