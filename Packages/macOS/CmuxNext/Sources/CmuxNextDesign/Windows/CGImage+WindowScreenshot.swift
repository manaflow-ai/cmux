public import AppKit

/// Cropping and encoding of a window screenshot. Not implemented yet.
extension CGImage {
    /// The part of this window image that shows `rect`.
    public nonisolated func cropped(toWindowRect rect: NSRect, windowSize: NSSize) -> CGImage? {
        nil
    }

    /// Whether no pixel of this image is visible.
    public nonisolated var isFullyTransparent: Bool {
        true
    }

    /// This image as PNG data.
    public nonisolated func pngData() -> Data? {
        nil
    }
}
