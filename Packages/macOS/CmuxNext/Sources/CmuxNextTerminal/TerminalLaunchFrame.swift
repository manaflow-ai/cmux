public import CoreGraphics

/// A terminal's frame from the last quit, shown at launch over the new session's surface until the
/// first content the owner sends is parsed and drawn (``TerminalFrameHold``), as an evicted
/// terminal's last frame is (``TerminalSession/showLastFrame(_:)``): no empty pane while it attaches.
@MainActor
public struct TerminalLaunchFrame {
    public let image: CGImage

    public init(_ image: CGImage) {
        self.image = image
    }

    /// Shows the frame over `session`; false when the session has content already, or holds a
    /// newer frame (an evicted terminal's last frame, ``TerminalLastFrames``).
    @discardableResult
    public func show(on session: TerminalSession) -> Bool {
        guard !session.surfaceHasContent, !session.frameHold.isHolding else { return false }
        session.frameHold.begin(lastFrame: .image(image), over: session.surfaceView, in: session.view)
        return true
    }
}
