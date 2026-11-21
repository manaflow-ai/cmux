public import CoreGraphics

/// A decoded window background image, ready to draw.
// SAFETY: A CGImage is immutable once created and Core Graphics allows reading
// it from any thread, so handing one from the decoding task to the main actor
// shares no mutable state. The struct holds nothing else.
public struct WindowBackgroundImage: @unchecked Sendable {
    /// The decoded bitmap, already rotated to its EXIF orientation.
    public let cgImage: CGImage

    /// Wraps a decoded bitmap.
    ///
    /// - Parameter cgImage: The bitmap to draw.
    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }
}
