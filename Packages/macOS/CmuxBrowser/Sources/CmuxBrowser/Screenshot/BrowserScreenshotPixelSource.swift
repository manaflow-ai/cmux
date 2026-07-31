public import AppKit

/// Supplies normalized sRGB snapshot colors in top-left-origin pixel coordinates.
public protocol BrowserScreenshotPixelSource {
    /// Pixel dimensions of the snapshot.
    var pixelSize: NSSize { get }

    /// Returns the pixel color at a top-left-origin point.
    ///
    /// - Parameter point: Pixel coordinate to sample.
    /// - Returns: A normalized sRGB color, or `nil` when the point cannot be sampled.
    func color(at point: NSPoint) -> BrowserScreenshotRGBA?
}
