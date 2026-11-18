public import AppKit

/// The view that places a pane's content (the layout's pane host), as content that keeps its own picture in a move
/// asks it (``PaneCommitMotionPicture``).
@MainActor
public protocol PaneCommitMotionContentHost: NSView {
    /// Keeps the pane's whole content at the size it has now, at the top-left corner of its pane, until
    /// ``releasePaneContentAfterMove()``. The content is larger than its pane then, and the pane's clip, which moves
    /// with the pane's edge, cuts it.
    func holdPaneContentForMove()
    /// The content takes the size that its pane gives it now, one time.
    func releasePaneContentAfterMove()
}

/// Pane content that is the picture of a page that draws in another process (a browser page, a chat).
///
/// Its picture at a new size comes some display frames after its view takes that size, and until then its view shows
/// the last picture at the old size, cut where the view got smaller. So it rides its pane's move
/// (``PaneCommitMotionRiding``) and, while its pane gets smaller, keeps its own picture
/// (``PaneCommitMotionHoldKind/ownPicture``): the pane's host keeps the whole content, its tabs and bars too, at the
/// size it had before the change, so no view in it takes a size. The pane's clip moves with the pane's edge, and the
/// picture is whole under it. The frame that ends the move gives the content its pane's size, one time.
///
/// A pane that grows gives its content its final size in the frame that shows the change, as with no move: the old
/// picture shows at its old size beside the page's own ground until the page's next frame.
///
/// A kind adopts it in one line: `extension SomeView: PaneCommitMotionPicture {}`.
@MainActor
public protocol PaneCommitMotionPicture: PaneCommitMotionRiding, PaneCommitMotionHolding {}

public extension PaneCommitMotionPicture {
    var paneCommitMotionHoldKind: PaneCommitMotionHoldKind { .ownPicture }
    func beginPaneCommitMotionHold() { paneCommitMotionContentHost?.holdPaneContentForMove() }
    func endPaneCommitMotionHold() { paneCommitMotionContentHost?.releasePaneContentAfterMove() }
}

public extension NSView {
    /// The nearest view over this one that places a pane's content; nil outside a pane. O(the view's depth).
    var paneCommitMotionContentHost: (any PaneCommitMotionContentHost)? {
        var ancestor = superview
        while let view = ancestor {
            if let host = view as? any PaneCommitMotionContentHost { return host }
            ancestor = view.superview
        }
        return nil
    }
}
