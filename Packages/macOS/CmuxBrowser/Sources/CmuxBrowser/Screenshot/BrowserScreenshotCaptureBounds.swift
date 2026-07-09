public import AppKit

/// The capture-area constraint for full-page browser screenshots: the maximum
/// number of pixels a single full-page capture may cover before it is rejected
/// as too large.
///
/// A bound is a value: it carries ``maximumFullPagePixels`` and validates a
/// candidate full-page content size against it.
public struct BrowserScreenshotCaptureBounds: Equatable, Sendable {
    /// The maximum pixel count (`ceil(width) × ceil(height)`) a full-page
    /// capture may cover.
    public let maximumFullPagePixels: CGFloat

    /// Creates a capture bound.
    /// - Parameter maximumFullPagePixels: the maximum pixel count a full-page
    ///   capture may cover. Defaults to 100,000,000.
    public init(maximumFullPagePixels: CGFloat = 100_000_000) {
        self.maximumFullPagePixels = maximumFullPagePixels
    }

    /// Validates that a full-page content size is finite, positive, and within
    /// ``maximumFullPagePixels``.
    /// - Parameter size: the full scrollable content size to validate.
    /// - Throws: ``BrowserScreenshotError/webContentMetricsUnavailable`` when the
    ///   size is non-finite or non-positive, or
    ///   ``BrowserScreenshotError/captureAreaTooLarge`` when the pixel count
    ///   exceeds ``maximumFullPagePixels``.
    public func validateFullPageSize(_ size: NSSize) throws {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }

        let pixelCount = ceil(size.width) * ceil(size.height)
        guard pixelCount <= maximumFullPagePixels else {
            throw BrowserScreenshotError.captureAreaTooLarge
        }
    }
}
