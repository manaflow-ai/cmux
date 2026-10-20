import AppKit
import Foundation
import ImageIO

/// Matches browser favicon decoding without making the pane module depend on the browser.
struct AgentPaneSourceIconPNG {
    nonisolated init() {}

    private nonisolated func isRaster(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) || // PNG
            bytes.starts(with: [0, 0, 1, 0]) || bytes.starts(with: [0, 0, 2, 0]) || // ICO, CUR
            bytes.starts(with: [255, 216, 255]) || bytes.starts(with: Array("GIF8".utf8)) ||
            bytes.starts(with: [73, 73, 42, 0]) || bytes.starts(with: [77, 77, 0, 42]) || // TIFF
            bytes.starts(with: Array("BM".utf8)) { return true }
        if bytes.starts(with: Array("RIFF".utf8)), bytes.count >= 12,
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
        // ISO base media raster images (AVIF/HEIF); other brands, including vector, stay out.
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            return ["avif", "avis", "heic", "heix", "mif1", "msf1"].contains(String(decoding: bytes[8..<12], as: UTF8.self))
        }
        return false
    }

    nonisolated func decode(_ data: Data) -> Data? {
        // Only recognized raster containers reach a native decoder. This body allowlist also
        // refuses SVG disguised by its URL, MIME type, XML prolog, BOM or text encoding.
        guard isRaster(data) else { return nil }
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
        } else { return nil }
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
