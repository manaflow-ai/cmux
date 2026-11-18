import AppKit
import CmuxNextDesign

/// MOVE HOLD. A split shows in one frame, and from that frame each pane's layer moves from its old rect to its new
/// one (`PaneCommitMotion`). Content that is the picture of a page (``PaneCommitMotionPicture``) asks its host to hold
/// it while its pane gets smaller:
///
/// - From the ask to the release the content keeps the size it had, at the clip's top-left corner (the corner the
///   pane's layer keeps while it moves). The host and its clip take their new frames as each pane does; the content
///   is larger than both, the clip cuts nothing, and the pane's own layer is the one clip over the content: the old
///   picture is whole under the edge that moves.
/// - The release (the frame that ends the move) gives the content its pane's size, one time. The content hears that
///   size before it takes it and that it rests after it (`PaneMotionTargeting`, `PaneMotionSettling`: a page shows
///   its frame at that size in the same commit when it comes in time).
/// - A second change before the release keeps the hold. A pane that has the held size again at the release resizes
///   nothing. A pane that a second change makes larger than the held size ends the hold in that change's frame
///   (`PaneClipView.setFrameSize`).
extension PaneHostView: PaneCommitMotionContentHost {
    /// The held content's frame in the clip; nil with no hold.
    var moveContentFrame: CGRect? { clipView.moveHeldSize.map { CGRect(origin: clipView.bounds.origin, size: $0) } }

    func holdPaneContentForMove() {
        // A key resize's hold and a layout spring place the content themselves.
        guard clipView.moveHeldSize == nil, !awaitsOwnLanding else { return }
        let now = content.frame.size
        guard now.width >= 1, now.height >= 1 else { return }
        clipView.moveHeldSize = now
    }

    func releasePaneContentAfterMove() {
        guard let held = clipView.moveHeldSize else { return }
        clipView.moveHeldSize = nil
        // A pane that left the layout (its close ended the hold) takes no size: it goes with the picture it had.
        guard let screen = superview as? ScreenContentView, screen.paneFrames[pane] != nil else { return }
        let rest = clipView.bounds.size
        guard rest != held else { return }
        content.notifyPaneMotionWillRest(sizeChange: CGSize(width: rest.width - held.width, height: rest.height - held.height))
        layOutLetGoContent()
        content.notifyPaneMotionSettled()
    }
}
