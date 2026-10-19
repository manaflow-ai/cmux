import AppKit
import Foundation
import ImageIO

/// Matches browser favicon decoding without making the pane module depend on the browser.
struct AgentPaneSourceIconPNG {
    nonisolated init() {}

    nonisolated func decode(_ data: Data) -> Data? {
        let maximumPixels = 64
        let side = CGFloat(maximumPixels)
        let best: CGImage
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
            // Thumbnail decoding bounds memory before any full-size raster exists.
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else { return nil }
            best = thumbnail
        } else {
            // AppKit handles vector formats ImageIO cannot read. Bound their canvas before rasterizing.
            guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0,
                  source.size.width <= 4096, source.size.height <= 4096 else { return nil }
            var proposed = CGRect(x: 0, y: 0, width: side, height: side)
            guard let image = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
                  image.width <= 4096, image.height <= 4096 else { return nil }
            best = image
        }
        let scale = min(1, side / CGFloat(max(best.width, best.height)))
        let width = max(1, Int((CGFloat(best.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(best.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(best, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
