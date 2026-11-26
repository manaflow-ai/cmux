#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

/// Reduces in-memory image attachments before they become ACP image blocks, for every
/// composer that attaches a photo (agent chat, terminal), so a phone photo crosses the link
/// once at 2048 px instead of at its camera size.
///
/// Image attachments are base64 encoded in the prompt, so keeping camera and pasted
/// originals at their full pixel dimensions makes both the phone-to-Mac transfer and
/// the prompt unnecessarily large. Animated images stay untouched because a single
/// thumbnail would discard their animation.
public enum ComposerImageOptimizer {
    public static let maxPixelSize = 2048
    public static let jpegQuality: CGFloat = 0.82

    public static func optimizeAsync(_ data: Data) async -> Data {
        await Task.detached(priority: .userInitiated) {
            optimize(data)
        }.value
    }

    /// Returns a smaller, orientation-correct image when ImageIO can decode it.
    /// The original bytes are retained when optimization would not save space.
    public static func optimize(_ data: Data) -> Data {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            return data
        }

        let sourceMIMEType = mimeType(data)
        if sourceMIMEType == "image/png",
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) <= maxPixelSize {
            return data
        }

        let hasAlpha: Bool
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            hasAlpha = true
        default:
            hasAlpha = false
        }
        let type: CFString = hasAlpha ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
        let alreadyAccepted = sourceMIMEType != nil
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return data }
        var properties: [CFString: Any] = [:]
        if !hasAlpha { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return data }
        let optimized = output as Data
        return alreadyAccepted && optimized.count >= data.count ? data : optimized
    }

    /// The image type agents accept, read from the bytes' signature (PNG, JPEG, GIF, WebP).
    public static func mimeType(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }

    public static func filename(_ name: String, for data: Data) -> String {
        guard !URL(fileURLWithPath: name).pathExtension.isEmpty,
              let mime = mimeType(data),
              let extensionName = UTType(mimeType: mime)?.preferredFilenameExtension else { return name }
        let url = URL(fileURLWithPath: name)
        guard url.pathExtension.caseInsensitiveCompare(extensionName) != .orderedSame else { return name }
        return url.deletingPathExtension().appendingPathExtension(extensionName).lastPathComponent
    }
}
#endif
