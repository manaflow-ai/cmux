import AppKit
import CmuxNextDesign

/// `PaneCommitMotion`, a pane beside the one that a zoom or an unzoom moves, whose content draws in a window of its
/// own (``PaneContentOwnWindow``).
///
/// Such a window is over the whole host window. The pane that grows does not cover it, the move's clip does not cut
/// it, and the dim over the other panes does not dim it. So a zoom over such a pane, and an unzoom beside one, shows
/// in one frame, as with the pane animations off, and the unzoom brings no dim.
///
/// The pane that moves has its own rule (`NSView.paneRidesCommitMotion`). This file reads the panes that do not move.
extension PaneCommitMotion {
    /// Whether the content of one of `hosts` shows a window of its own now.
    static func showsOwnWindow(_ hosts: [PaneHostView]) -> Bool {
        hosts.contains { $0.content.paneShowsOwnWindow }
    }

    /// Whether a pane that `screen` shows now, other than `pane`, shows a window of its own. An unzoom of `pane` then
    /// brings no dim: the dim would be on each other pane but that one.
    static func showsOwnWindow(on screen: ScreenContentView, beside pane: PaneID) -> Bool {
        let others = screen.paneFrames.keys.filter { $0 != pane }.compactMap { screen.context.hosts[$0] }
        return showsOwnWindow(others.filter { $0.superview === screen && !$0.isHidden })
    }
}

extension NSView {
    /// Whether this pane content shows content that is drawn in a window of its own now: the top view of its content
    /// area, or the content itself when its area shows no such view, is a ``PaneContentOwnWindow`` that draws so, or
    /// has a shown direct subview that is one. This is the walk that `NSView.paneRidesCommitMotion` makes for the pane
    /// that moves; a row of `PaneCommitMotionTests` holds the two equal.
    /// O(that view's subviews), no layout.
    var paneShowsOwnWindow: Bool {
        let view = paneCommitMotionTop ?? self
        if let own = view as? any PaneContentOwnWindow, own.drawsInOwnWindow { return true }
        return view.subviews.contains { !$0.isHidden && ($0 as? any PaneContentOwnWindow)?.drawsInOwnWindow == true }
    }
}
