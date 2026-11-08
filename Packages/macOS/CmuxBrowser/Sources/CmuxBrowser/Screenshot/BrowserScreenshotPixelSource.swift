public import AppKit

/// Supplies normalized sRGB snapshot colors in top-left-origin pixel coordinates.
public protocol BrowserScreenshotPixelSource {
    /// Pixel dimensions of the snapshot.
    var pixelSize: NSSize { get }

    /// Returns regularly spaced colors from a top-left-origin pixel rectangle.
    ///
    /// - Parameters:
    ///   - rect: Integral pixel rectangle to sample.
    ///   - stride: Positive distance between sampled pixels on each axis.
    /// - Returns: Row-major normalized sRGB colors, or `nil` when the rectangle
    ///   cannot be sampled completely.
    func colors(in rect: NSRect, stride: Int) -> [BrowserScreenshotRGBA]?
}

extension BrowserScreenshotPixelSource {
    /// Returns one pixel by issuing a one-pixel bulk sample.
    ///
    /// - Parameter point: Top-left-origin pixel coordinate to sample.
    /// - Returns: A normalized sRGB color, or `nil` when the point cannot be sampled.
    public func color(at point: NSPoint) -> BrowserScreenshotRGBA? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        return colors(
            in: NSRect(x: x, y: y, width: 1, height: 1),
            stride: 1
        )?.first
    }
}
