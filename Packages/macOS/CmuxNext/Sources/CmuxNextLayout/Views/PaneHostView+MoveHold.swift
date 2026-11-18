import AppKit
import CmuxNextDesign

/// MOVE HOLD. A split shows in one frame, and from that frame each pane's layer moves from its old rect to its new
/// one (`PaneCommitMotion`). Content that is the picture of a page (``PaneCommitMotionPicture``) asks its host to hold
/// it while its pane gets smaller:
///
/// - From the ask to the release the content keeps the size it had, at the clip's top-left corner (the corner the
///   pane's layer keeps while it moves). The host and its clip take their new frames as each pane does, so the
///   content is larger than both. The clip's layer gets the pane's change of size as a move
///   (``PaneCommitMotion/moveClip(of:_:)``): it cuts the content at the pane's inset and with the pane's corners in
///   each frame, from the old rect to the new one. The old picture is whole under the edge that moves, and the end
///   of the move changes no edge.
/// - The release (the frame that ends the move) gives the content its pane's size, one time. The content hears that
///   size before it takes it and that it rests after it (`PaneMotionTargeting`, `PaneMotionSettling`: a page shows
///   its frame at that size in the same commit when it comes in time).
/// - A second change before the release keeps the hold. A pane that has the held size again at the release resizes
///   nothing. A pane that a second change makes larger than the held size ends the hold in that change's frame
///   (`PaneClipView.setFrameSize`).
/// - A resize key before the release begins the key's hold with the held picture. That hold keeps the same corner,
///   so the release moves nothing and gives no size: the one size comes after the key's landing.
extension PaneHostView: PaneCommitMotionContentHost {
    /// The held content's frame in the clip; nil with no hold.
    var moveContentFrame: CGRect? { clipView.moveHeldSize.map { CGRect(origin: clipView.bounds.origin, size: $0) } }

    /// Whether this host keeps its content at an old size now. A host can refuse a hold that its content asks for
    /// (``holdPaneContentForMove()``), so an unzoom asks here whether its pane has its old picture, not the motion.
    var holdsContentForMove: Bool { clipView.moveHeldSize != nil }

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
        // A pane that a close took out takes no size: it goes with the picture it had. A pane that a zoom covers
        // comes back with the unzoom, so it takes its size here, in the frame that hides it.
        guard let screen = superview as? ScreenContentView, !screen.context.isClosing(pane) else { return }
        // A resize key in the move began the key's hold with this picture: that hold keeps it at the same corner and
        // gives the one size after the key's landing. The content only takes that hold's frame here.
        guard !holdsUntilAfterLanding else { return layOutLetGoContent() }
        let rest = clipView.bounds.size
        guard rest != held else { return }
        content.notifyPaneMotionWillRest(sizeChange: CGSize(width: rest.width - held.width, height: rest.height - held.height))
        layOutLetGoContent()
        content.notifyPaneMotionSettled()
    }
}

extension PaneCommitMotion {
    /// The inner clip of a pane whose content is held gets the change of size of the pane's move. Its frame is the
    /// pane's less a constant inset, so its edge goes with the pane's edge.
    func moveClip(of change: Change, _ token: MotionSpring) {
        guard holds[ObjectIdentifier(change.host)] != nil, let clip = change.host.clipView.layer else { return }
        move(clip, token, origin: .zero, size: change.size)
    }

    /// The end of one hold. The holder hears it, and a page's view passes it to the host that it is in. That view
    /// can be out of its pane by now (its tab closed, or another pane took it), so the host that began the hold is
    /// told here too: no host keeps its content at an old size after the motion's end. A host with no hold does nothing.
    func endHold(_ holder: any PaneCommitMotionHolding, of host: PaneHostView) {
        holder.endPaneCommitMotionHold()
        host.releasePaneContentAfterMove()
    }
}
