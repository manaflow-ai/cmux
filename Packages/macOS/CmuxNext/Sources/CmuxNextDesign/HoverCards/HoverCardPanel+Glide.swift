import AppKit
import CmuxNextDesignTokens

// One tab card that glides (Lawrence 2026-11-15, msg 34360, a recording of the pointer crossing a tab
// strip: "this animation needs to be better"). Frame by frame the old card jumped most of the way to a
// far tab (its slide was clamped to `travel`), snapped to each tab on a quick move (the sidebar's sweep
// rule), and crossfaded one snapshot of the last card stretched over the next card's size, so the last
// tab's text drew shifted and doubled over the next one and past the card's edge. Now a tab or chip
// card moves the whole way on the glide's one spring (`morph(from:always:)`: the window holds both
// places, the mask resizes about the corner on the tab), a move mid-glide restarts it from where the
// card is drawn, and the content crossfades as two views: the last card's at its own size, pinned to
// the fixed corner and clipped by the card's mask, fades out (`fadeOut`, the shorter fade) while the
// next card's fades in (`fadeIn`). Reduce Motion: the card is at its tab at once, its content swapped
// in place. Sidebar cards keep their sweep and their `travel` slide (msg 15501).
extension HoverCardPanel {
    /// Cards that glide the whole way between targets: the ones that hang from a tab or a chip.
    static func glidesWholeWay(_ placement: HoverCardPlacement) -> Bool {
        placement == .below || placement == .above
    }

    /// `view` (the last card's content) fades out where it is drawn, at its own size and pinned to
    /// the card's fixed corner while the card resizes under it; it leaves at the end of the fade, or
    /// with the glide (`endLeaving()`), whichever comes first.
    func leave(_ view: NSView) {
        endLeaving()
        NSLayoutConstraint.deactivate(edgeConstraints + sizeConstraints)
        let frame = view.frame
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = frame
        let corner = fixedCorner
        let flipped = view.superview?.isFlipped == true
        let top = (corner.y == 1) != flipped
        view.autoresizingMask = [corner.x == 0 ? .maxXMargin : .minXMargin, top ? .minYMargin : .maxYMargin]
        leavingBody = view
        view.wantsLayer = true
        guard let layer = view.layer else { return endLeaving() }
        CATransaction.begin()
        CATransaction.setMainCompletion { [weak self, weak view] in
            guard let self, let view, self.leavingBody === view else { return }
            self.endLeaving()
        }
        Motion.hoverCards.set(layer, "opacity", to: Float(0), fade: .fadeOut, from: Float(1))
        CATransaction.commit()
    }

    /// The next card's content fades in over the leaving one.
    func fadeIn(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        Motion.hoverCards.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
    }

    /// The leaving content goes now, its fade ended. It stays clear: made whole while still in the
    /// window, it drew at full strength for one frame before AppKit took its layer out (the live
    /// recording of the first fix). `present` makes it whole and shown when it shows again.
    func endLeaving() {
        guard let view = leavingBody else { return }
        leavingBody = nil
        if let layer = view.layer {
            layer.removeAnimation(forKey: "opacity")
            Motion.setModel(layer, "opacity", Float(0))
        }
        // Hidden where it is (frame-placed, no constraints), for the next swap to show again; one view
        // at most waits so (another source's body that left goes out of the window).
        view.isHidden = true
        if let parked = parkedBody, parked !== view, parked !== body { parked.removeFromSuperview() }
        parkedBody = view
    }
}

/// What the last `present` decided (`debug.hover_cards` `last_present`, live checks of the glide).
struct HoverCardPresentNote {
    var onScreen = false, glides = false, sweeping = false, fadesBodies = false, sameBody = false
    var moves = false, liveResize = false, morphed = false

    var text: String {
        [("on_screen", onScreen), ("glides", glides), ("sweeping", sweeping), ("fades_bodies", fadesBodies),
         ("same_body", sameBody), ("moves", moves), ("live_resize", liveResize), ("morphed", morphed)]
            .map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}
