public import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Cropping and encoding of a window screenshot (``NSWindow/screenshotImage(includeChild:)``).
extension CGImage {
    /// The part of this window image that shows `rect`, or nil when it
    /// shows none of it.
    ///
    /// - Parameters:
    ///   - rect: A rectangle in window coordinates (bottom-left origin,
    ///     points), such as `view.convert(view.bounds, to: nil)`.
    ///   - windowSize: The window frame's size in points; this image covers
    ///     the whole frame.
    /// - Returns: The cropped image, clipped to the window.
    public nonisolated func cropped(toWindowRect rect: NSRect, windowSize: NSSize) -> CGImage? {
        guard windowSize.width > 0, windowSize.height > 0, !rect.isEmpty else { return nil }
        let scaleX = CGFloat(width) / windowSize.width
        let scaleY = CGFloat(height) / windowSize.height
        // An image's rows run top down; window coordinates bottom up.
        let pixels = CGRect(x: rect.minX * scaleX, y: (windowSize.height - rect.maxY) * scaleY,
                            width: rect.width * scaleX, height: rect.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !pixels.isEmpty else { return nil }
        return cropping(to: pixels)
    }

    /// This image redrawn at `width` x `height` pixels, or itself when it
    /// already has that size; nil when either side is not positive or no
    /// bitmap context can be made.
    public nonisolated func resampled(width newWidth: Int, height newHeight: Int) -> CGImage? {
        guard newWidth > 0, newHeight > 0 else { return nil }
        if width == newWidth, height == newHeight { return self }
        guard let context = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    /// Whether no pixel of this image is visible (every alpha zero, sampled
    /// at 64 x 64). A capture that comes back this way failed.
    public nonisolated var isFullyTransparent: Bool {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(self, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return true }
        return !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
    }

    /// This image as PNG data, or nil when ImageIO cannot encode it.
    public nonisolated func pngData() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, self, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
