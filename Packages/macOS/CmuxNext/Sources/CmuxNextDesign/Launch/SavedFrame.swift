public import AppKit

/// One pane's last frame from the last quit (a terminal's or an agent page's), decoded: the
/// launch draws it until the pane's live content paints (``SavedFrameDirectory``).
public nonisolated struct SavedFrame: Sendable {
    /// The decoded pixels (decoded when read, so drawing it costs no decode on the main thread).
    public let image: CGImage
    /// The backing scale it was saved at (1, 2 or 3), from its file name.
    public let scale: Int

    /// Its size in points.
    public var size: NSSize {
        NSSize(width: CGFloat(image.width) / CGFloat(scale), height: CGFloat(image.height) / CGFloat(scale))
    }

    /// An image of ``image`` at its point size.
    public func makeImage() -> NSImage {
        NSImage(cgImage: image, size: size)
    }
}
