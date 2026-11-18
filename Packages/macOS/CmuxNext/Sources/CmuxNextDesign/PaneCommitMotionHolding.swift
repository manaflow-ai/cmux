public import AppKit

/// How a pane's content keeps its old picture while its pane gets smaller in a move.
public enum PaneCommitMotionHoldKind: Sendable {
    /// The content keeps its own picture at its old size from ``PaneCommitMotionHolding/beginPaneCommitMotionHold()``
    /// to ``PaneCommitMotionHolding/endPaneCommitMotionHold()``, and takes its new size one time, at the end. The
    /// motion adds nothing over it and no ground beside it.
    case ownPicture
    /// The content has its new size in the frame that shows the change. Where its old picture must show for the
    /// motion's time (an unzoom), the motion shows the content's last frame in a layer of its own.
    case lastFrame
}

/// A view that keeps a pane's old picture while the pane gets smaller in a move (a split's old pane, an unzoom's pane).
///
/// The motion asks the pane's content for its holder (``AppKit/NSView/paneCommitMotionHolder``) before the frame that
/// shows the change places the panes and gives them their sizes:
///
/// - ``PaneCommitMotionHoldKind/ownPicture``: it calls ``beginPaneCommitMotionHold()`` then, and
///   ``endPaneCommitMotionHold()`` in the frame that ends the motion. A second act while the panes move ends no hold:
///   each hold goes on to the end of the last motion, and the content takes its newest size there, one time.
/// - ``PaneCommitMotionHoldKind/lastFrame``: it calls neither at a split or a close.
///
/// Each `begin` gets one `end`, also when the change then shows in one frame.
@MainActor
public protocol PaneCommitMotionHolding: NSView {
    var paneCommitMotionHoldKind: PaneCommitMotionHoldKind { get }
    /// The pane gets smaller in a change that the next frame shows: keep the picture that shows now.
    func beginPaneCommitMotionHold()
    /// The hold is over: take the size that the pane has now.
    func endPaneCommitMotionHold()
}

public extension NSView {
    /// The view that holds this pane content's old picture in a move: this view, or the top view that shows in its
    /// content area and fills it (``paneCommitMotionTop``). Nil: the content holds nothing. O(the area's views).
    var paneCommitMotionHolder: (any PaneCommitMotionHolding)? {
        (self as? any PaneCommitMotionHolding) ?? (paneCommitMotionTop as? any PaneCommitMotionHolding)
    }
}
