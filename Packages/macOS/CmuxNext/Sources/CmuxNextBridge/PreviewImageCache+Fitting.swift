public import CoreGraphics

/// Page pictures for hover cards and drag images (R131): a page snapshot is the page's full size; it is scaled to the
/// card's pixel size off the main thread, so the card's layer never decodes and scales a full page in a frame.
extension PreviewImageCache {
    /// The size a page thumbnail is kept at (covers the hover card and the tab drag ghost at 2x).
    public static let pagePixelSize = CGSize(width: 640, height: 640)

    /// `image` scaled to fit `maxPixelSize` (never up), on a background task.
    public static func fit(_ image: CGImage, _ maxPixelSize: CGSize) async -> CGImage {
        if image.width <= Int(maxPixelSize.width), image.height <= Int(maxPixelSize.height) { return image }
        return await Task.detached(priority: .userInitiated) { fitted(image, maxPixelSize) }.value
    }

    /// `image` scaled to fit `maxPixelSize` and drawn into a bitmap on a background task: an image that decodes from
    /// compressed data is never decoded on the main thread by the view that shows it.
    public static func decoded(_ image: CGImage, _ maxPixelSize: CGSize) async -> CGImage {
        await Task.detached(priority: .userInitiated) {
            let scaled = fitted(image, maxPixelSize)
            return scaled === image ? redrawn(image) : scaled  // a scaled image is already a bitmap of its own
        }.value
    }

    /// `image` drawn once into a bitmap of its own size.
    private nonisolated static func redrawn(_ image: CGImage) -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// `image` scaled to fit `maxPixelSize` (never up), here.
    public nonisolated static func fitted(_ image: CGImage, _ maxPixelSize: CGSize) -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(maxPixelSize.width / max(width, 1), maxPixelSize.height / max(height, 1), 1)
        guard scale < 1 else { return image }
        let size = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }
}
