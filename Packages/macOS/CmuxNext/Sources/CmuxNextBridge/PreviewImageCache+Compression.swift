public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Page pictures kept compressed (Chrome's ThumbnailImage keeps one compressed thumbnail per tab): a JPEG, or a PNG
/// when the picture has transparent pixels, which JPEG would turn black.
extension PreviewImageCache {
    /// Pixels a compressed picture keeps at most: a 2560 x 1600 pt pane at 2x (16.4 M) keeps its size.
    public nonisolated static let maxCompressedPixels = 16 << 20

    /// Keeps `image` for `key` now, and replaces it with its compressed copy when that is encoded, off every waiting
    /// path at .utility: a caller that waits for this picture never waits for its compression. The replacement is
    /// dropped when `key` holds another picture by then (a later capture is never overwritten by an older one).
    public func insertCompressingLater(_ image: CGImage, for key: String) {
        insert(image, for: key)
        let encode = self.encode
        Task.detached(priority: .utility) { [weak self] in
            guard let kept = await encode(image) else { return }
            await self?.replace(image, for: key, with: kept.image, cost: kept.data.count)
        }
    }

    /// `image` as a JPEG (a PNG when it has transparent pixels) at most `maxCompressedPixels` large, same aspect and
    /// color space, with the image that decodes from it; nil when ImageIO cannot encode it. Encodes here.
    public nonisolated static func compressed(_ image: CGImage, quality: Double) -> (data: Data, image: CGImage)? {
        let pixels = Double(image.width * image.height)
        let scale = min(1, (Double(maxCompressedPixels) / max(pixels, 1)).squareRoot())
        let source = scale < 1
            ? fitted(image, CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
            : image
        let data = NSMutableData()
        let type = isOpaque(source) ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let reader = CGImageSourceCreateWithData(data, nil),
              let decoded = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return (data as Data, decoded)
    }

    /// True when `image` has no alpha, or no transparent pixel in a 32 x 32 sample of it (a
    /// transparent background spans most of a page; an engine's opaque picture often has alpha).
    nonisolated static func isOpaque(_ image: CGImage) -> Bool {
        if [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return true }
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: side * side * 4) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: side * side * 4, by: 4).allSatisfy { pixels[$0] == 255 }
    }
}
