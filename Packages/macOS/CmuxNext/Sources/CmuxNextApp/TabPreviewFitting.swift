import CoreGraphics

/// Hover card thumbnails of browser pages (R131): a page snapshot is the
/// page's full size; it is scaled to the card's pixel size off the main
/// thread, so the card's layer never decodes and scales a full page in a
/// frame.
enum TabPreviewFitting {
    /// `image` scaled to fit `maxPixelSize` (never up), on a background task.
    static func fit(_ image: CGImage, _ maxPixelSize: CGSize) async -> CGImage {
        await Task.detached(priority: .userInitiated) { fitted(image, maxPixelSize) }.value
    }

    nonisolated static func fitted(_ image: CGImage, _ maxPixelSize: CGSize) -> CGImage {
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
