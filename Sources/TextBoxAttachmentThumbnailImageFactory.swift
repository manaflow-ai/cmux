import AppKit
import CmuxFoundation
import CoreGraphics
import Foundation

@MainActor
enum TextBoxAttachmentThumbnailImageFactory {
    static func image(
        from pixels: TextBoxInlineAttachmentThumbnailPixels,
        pointSize: NSSize
    ) -> NSImage? {
        guard pixels.rgba8.count == pixels.bytesPerRow * pixels.size.height,
              let provider = CGDataProvider(data: pixels.rgba8 as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(
                  width: pixels.size.width,
                  height: pixels.size.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: pixels.bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                          | CGImageAlphaInfo.premultipliedLast.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: pointSize)
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }
}
