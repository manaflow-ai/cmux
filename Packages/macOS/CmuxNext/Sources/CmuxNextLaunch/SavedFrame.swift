public import CoreGraphics

/// One pane's last frame from the last quit (a terminal's or an agent page's), decoded: the
/// launch draws it until the pane's live content paints (``SavedFrameDirectory``).
public struct SavedFrame: Sendable {
    /// The decoded pixels (decoded when read, so drawing it costs no decode on the main thread).
    public let image: CGImage
    /// The backing scale it was saved at (1, 2 or 3), from its file name.
    public let scale: Int

    /// A decoded frame, as a ``SavedFrameDirectory`` decoder returns it.
    ///
    /// Visible to the package as the directory's `init(url:name:decode:)` is: that decoder returns a
    /// `SavedFrame`, so a decoder written outside this module (a test that holds its decodes) builds
    /// its frames here.
    /// - Parameters:
    ///   - image: The decoded pixels.
    ///   - scale: The backing scale the frame was saved at (1, 2 or 3), from its file name.
    package init(image: CGImage, scale: Int) {
        self.image = image
        self.scale = scale
    }

    /// Its size in points (`NSImage(cgImage: frame.image, size: frame.size)` draws it).
    public var size: CGSize {
        CGSize(width: CGFloat(image.width) / CGFloat(scale), height: CGFloat(image.height) / CGFloat(scale))
    }
}
