import AppKit

/// The divider lines that an unzoom brings back, in a window that gives a pane no ground.
///
/// An unzoom's layout brings each divider back in the pass that shows it, under the pane that still has the screen's
/// size and closes to its place. With a ground that pane covers the lines. With none (a glass window) a line under it
/// would show through it. So such a line is held back with no animation, and the motion's end shows it: the plain
/// end, the end after a second act in the move and the end of a motion that is cut all go through
/// ``PaneCommitMotion/finish()``. A divider that a split or a close brings in its own pass keeps its move.
extension PaneCommitMotion {
    /// Holds the line of `view` back to the motion's end, when the pane of `change` (the one that an unzoom closes)
    /// has no ground under its content.
    func holdLine(of view: DividerHandleView, under change: Change) {
        guard !view.holdsLineBack, !sheets.contains(where: { $0.host === change.host }) else { return }
        view.holdsLineBack = true
        lateLines.append(view)
    }

    /// Shows each line that the motion held back, and asks the screen for the overlay's rects again: a page under a
    /// line leaves it uncovered from this frame.
    func showLines() {
        guard !lateLines.isEmpty else { return }
        for view in lateLines { view.holdsLineBack = false }
        let screens = Set(lateLines.compactMap { $0.superview as? ScreenContentView })
        lateLines = []
        for screen in screens { screen.context.overlayNeedsSync() }
    }
}
