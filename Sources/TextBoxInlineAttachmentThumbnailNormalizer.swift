import CoreGraphics
import Foundation
import ImageIO

struct TextBoxInlineAttachmentThumbnailNormalizer:
    TextBoxInlineAttachmentThumbnailNormalizing
{
    func normalizedThumbnail(
        for fileURL: URL,
        pixelSize: TextBoxInlineAttachmentThumbnailSize
    ) -> TextBoxInlineAttachmentThumbnailPixels? {
        guard !isCurrentTaskCancelled() else { return nil }
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelSize.width, pixelSize.height),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let sourceThumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ), !isCurrentTaskCancelled(),
           let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let bytesPerRow = pixelSize.width * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: pixelSize.width,
            height: pixelSize.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: sRGB,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(
            sourceThumbnail,
            in: CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
        )
        guard !isCurrentTaskCancelled(), let data = context.data else { return nil }

        return TextBoxInlineAttachmentThumbnailPixels(
            size: pixelSize,
            bytesPerRow: bytesPerRow,
            rgba8: Data(bytes: data, count: bytesPerRow * pixelSize.height)
        )
    }

    private func isCurrentTaskCancelled() -> Bool {
        withUnsafeCurrentTask { $0?.isCancelled == true }
    }
}
