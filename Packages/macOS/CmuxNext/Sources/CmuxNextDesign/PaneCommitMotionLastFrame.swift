public import AppKit

/// The picture that a pane's content showed last, with what a layer needs to show it again as it was.
///
/// An unzoom makes its pane smaller in one frame, and the pane's clip then closes from the screen's size to the
/// pane's place. For that time the motion shows this picture over the content, at the size it had, so the room that
/// the clip still has shows what the pane showed there and not a ground.
public struct PaneCommitMotionLastFrame {
    /// A layer's contents: the picture's pixels. The motion keeps this reference and copies no pixel.
    public let contents: Any
    /// How the layer that showed the picture placed it in its bounds, and the picture's pixels for each point.
    public let gravity: CALayerContentsGravity
    public let scale: CGFloat
    /// Where the picture showed, in the coordinates of the view that gives it.
    public let rect: CGRect

    public init(contents: Any, gravity: CALayerContentsGravity, scale: CGFloat, rect: CGRect) {
        self.contents = contents
        self.gravity = gravity
        self.scale = scale
        self.rect = rect
    }
}

/// A view that can give the picture that it shows now (``PaneCommitMotionLastFrame``).
///
/// The motion asks one time for each unzoom, in the turn of its key, before the pane's content hears its new size.
/// It asks for nothing on a frame.
@MainActor
public protocol PaneCommitMotionLastFrameGiving: NSView {
    /// The picture that shows now; nil: the view has none yet.
    var paneCommitMotionLastFrame: PaneCommitMotionLastFrame? { get }
}

public extension NSView {
    /// The view that gives this pane content's last frame: this view, or the top view that shows in its content area
    /// and fills it (``paneCommitMotionTop``). Nil: the content gives none. O(the area's views).
    var paneCommitMotionLastFrameGiver: (any PaneCommitMotionLastFrameGiving)? {
        (self as? any PaneCommitMotionLastFrameGiving) ?? (paneCommitMotionTop as? any PaneCommitMotionLastFrameGiving)
    }
}
