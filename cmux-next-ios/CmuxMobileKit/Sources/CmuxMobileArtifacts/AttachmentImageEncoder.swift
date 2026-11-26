#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO
import CmuxMobileTransport
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
        // A multi-frame image must retain all frames. A thumbnail would silently
        // turn animated WebP, TIFF, GIF, APNG, or a burst into a still image.
        let typeName = typeIdentifier as String
        // HEIC bursts expose several images. The phone's image attachment is the
        // primary frame, so a transfer copy may use that frame. Animated formats
        // and multipage documents must keep their original bytes.
        let isHEIF = typeName == UTType.heic.identifier || typeName == UTType.heif.identifier
        guard frameCount == 1 || isHEIF else { return nil }
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

    /// Makes a transfer copy from a picked file while its security scope is open.
    /// Returning nil keeps the URL streamable when the original is already smaller
    /// or when the format must retain all of its frames.
    package static func encode(fileURL: URL, byteCount: Int? = nil,
                               allowLargerCopy: Bool = false) -> (data: Data, ext: String)? {
        ScopedFile(fileURL).withAccess { url in
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
                  let typeIdentifier = CGImageSourceGetType(source) else { return nil }
            let typeName = typeIdentifier as String
            let frameCount = CGImageSourceGetCount(source)
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
            let type: CFString = hasAlpha ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
            var properties: [CFString: Any] = [:]
            if !hasAlpha { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            let optimized = output as Data
            let originalSize = byteCount ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max)
            guard optimized.count < originalSize || allowLargerCopy ||
                ![UTType.jpeg.identifier, UTType.png.identifier, UTType.gif.identifier,
                  UTType.webP.identifier].contains(typeName) else { return nil }
            return (optimized, hasAlpha ? "png" : "jpg")
        }
    }
}
#endif
