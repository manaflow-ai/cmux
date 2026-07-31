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

    /// Returns regularly spaced colors from a top-left-origin pixel rectangle.
    ///
    /// - Parameters:
    ///   - rect: Pixel rectangle to sample.
    ///   - stride: Positive distance between sampled pixels on each axis.
    /// - Returns: Row-major normalized sRGB colors, or `nil` when the rectangle
    ///   cannot be sampled completely.
    func colors(in rect: NSRect, stride: Int) -> [BrowserScreenshotRGBA]?
}

public extension BrowserScreenshotPixelSource {
    /// Samples a rectangle through ``color(at:)``.
    func colors(in rect: NSRect, stride: Int) -> [BrowserScreenshotRGBA]? {
        let minX = Int(rect.minX.rounded(.down))
        let minY = Int(rect.minY.rounded(.down))
        let maxX = Int(rect.maxX.rounded(.up)) - 1
        let maxY = Int(rect.maxY.rounded(.up)) - 1
        guard stride > 0, minX <= maxX, minY <= maxY else { return nil }

        var result: [BrowserScreenshotRGBA] = []
        let columnCount = (maxX - minX) / stride + 1
        let rowCount = (maxY - minY) / stride + 1
        result.reserveCapacity(columnCount * rowCount)
        for y in Swift.stride(from: minY, through: maxY, by: stride) {
            for x in Swift.stride(from: minX, through: maxX, by: stride) {
                guard let color = color(
                    at: NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                ) else {
                    return nil
                }
                result.append(color)
            }
        }
        return result
    }
}
