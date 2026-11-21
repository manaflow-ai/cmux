/// An unrendered static or animated surface-tab icon supplied over the socket.
///
/// Wire parsing permits 1–64 frames, at most 512 KiB of total SVG UTF-8,
/// and at most 30 seconds of aggregate duration. SVG safety and rasterization
/// belong to the app, not this transport DTO.
public struct ControlSurfaceIconAsset: Sendable, Equatable {
    /// The ordered, untrusted SVG frames.
    public let frames: [ControlSurfaceIconFrame]

    /// Whether animation repeats after the last frame.
    public let loop: Bool

    /// The zero-based frame used when animation is unavailable or disabled.
    public let staticFrame: Int

    /// Creates a raw asset without rendering or validating SVG syntax.
    ///
    /// - Parameters:
    ///   - frames: The ordered SVG frames.
    ///   - loop: Whether playback repeats.
    ///   - staticFrame: The fallback frame index; defaults to the first frame.
    public init(frames: [ControlSurfaceIconFrame], loop: Bool, staticFrame: Int = 0) {
        self.frames = frames
        self.loop = loop
        self.staticFrame = staticFrame
    }
}
