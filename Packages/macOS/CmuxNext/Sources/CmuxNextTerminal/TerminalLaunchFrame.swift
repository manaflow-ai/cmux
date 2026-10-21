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

    /// Shows the frame over `session`; false when the session has content already.
    @discardableResult
    public func show(on session: TerminalSession) -> Bool {
        guard !session.surfaceHasContent else { return false }
        session.frameHold.begin(lastFrame: image, over: session.surfaceView, in: session.view)
        return true
    }
}
