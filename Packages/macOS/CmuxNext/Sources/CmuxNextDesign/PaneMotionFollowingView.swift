public import AppKit

/// A pane's whole content that follows its pane in every frame of a keyboard resize's hold (``PaneMotionHoldFollowing``)
/// instead of keeping the size it had when the hold began. For in-process content that lays out cheaply at each frame's
/// size. Held content keeps its start size on the hold's edges and the pane cuts it where it is narrower: a chat cut
/// there loses its right side, where my messages' bubbles are (a102, clipped blue bubbles in cmux NEXT Home).
///
/// Subclass it in place of `NSView`:
///
/// ```swift
/// final class HomeHostView: PaneMotionFollowingView { ... }
/// ```
///
/// The pane's content area (``PaneContentAreaView``) gives the view its own bounds on every frame of the hold; the view
/// lays out at that size in the frame's layout pass.
@MainActor
open class PaneMotionFollowingView: NSView, PaneMotionHoldFollowing {
    /// Lays the view out again: the area gives it its bounds on every frame of `hold`, and its frame back when it ends.
    /// - Parameter hold: The hold's edges, or nil when the hold ended.
    /// - Parameter heldSize: The area's size when the hold began, or nil when it ended.
    open func followPaneMotion(_ hold: PaneMotionHold?, heldSize: CGSize?) {
        needsLayout = true
    }

    /// Shown during its pane's hold (a tab switch back to it): it follows the pane from this frame.
    open override func viewDidUnhide() {
        super.viewDidUnhide()
        (superview as? PaneContentAreaView)?.followerDidShow()
    }
}
