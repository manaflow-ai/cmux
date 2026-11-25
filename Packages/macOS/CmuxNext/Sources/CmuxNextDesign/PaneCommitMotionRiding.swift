public import AppKit

/// A view that can ride its pane's move at a split, a close or a zoom: it has its final size and place in the frame
/// that shows the change, and while the pane's clip moves over it for a tenth of a second it shows no cut and no
/// stretched frame. A terminal's host is one: its surface is drawn at the new size for that frame.
///
/// The marker is all a kind states. A kind with no marker does not ride: a change that would move its pane shows in
/// one frame, as it does with the pane animations off.
@MainActor
public protocol PaneCommitMotionRiding: NSView {}

public extension NSView {
    /// Whether this pane content rides its pane's move now: the top view that shows in its content area and fills it
    /// is a ``PaneCommitMotionRiding`` view, or the content has no area and is one itself. Views under the top one
    /// are covered, and a hidden view (a parked tab) shows nothing. An area with another kind on top does not ride,
    /// whatever its container is: what the area shows is what the moving clip would cut.
    ///
    /// An area that shows no view yet and has the ground of a terminal that comes next
    /// (``PaneContentAreaView/waitingGround``: a split's new pane in its key's frame) rides: a flat ground has
    /// nothing to cut, and the terminal's host comes into it at its final size.
    /// O(the area's views), no layout.
    ///
    /// A riding view that shows content drawn in a window of its own (``PaneContentOwnWindow``: itself or a direct
    /// subview, a cmux page on the Chromium engine) does not ride: the move's clip does not cut that window.
    var paneRidesCommitMotion: Bool {
        guard let area = paneCommitMotionArea else { return self is any PaneCommitMotionRiding && !drawsInOwnWindowNow }
        guard area.bounds.width >= 1, area.bounds.height >= 1 else { return false }
        guard let top = paneCommitMotionTop else { return area.waitingGround != nil }
        return top is any PaneCommitMotionRiding && !top.drawsInOwnWindowNow
    }

    /// Whether this view, or a shown direct subview of it, draws in a window of its own now (``PaneContentOwnWindow``).
    /// O(its subviews), no layout.
    private var drawsInOwnWindowNow: Bool {
        if let own = self as? any PaneContentOwnWindow, own.drawsInOwnWindow { return true }
        return subviews.contains { !$0.isHidden && ($0 as? any PaneContentOwnWindow)?.drawsInOwnWindow == true }
    }

    /// This pane content's area: the view itself, or its first direct subview that is one.
    private var paneCommitMotionArea: PaneContentAreaView? {
        if let area = self as? PaneContentAreaView { return area }
        return subviews.lazy.compactMap { $0 as? PaneContentAreaView }.first
    }

    /// The top view that shows in this pane content's area and fills it; nil: the area shows no such view, or the
    /// content has no area.
    var paneCommitMotionTop: NSView? {
        guard let area = paneCommitMotionArea else { return nil }
        let room = area.bounds.insetBy(dx: 0.5, dy: 0.5)
        return area.subviews.last { !$0.isHidden && $0.alphaValue > 0 && $0.frame.contains(room) }
    }
}
