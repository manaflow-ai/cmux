import AppKit
import CmuxNextDesign

/// The bottom card slot's room in the sidebar: the list's bottom
/// edge makes room for a card, and takes it back, on a render-server spring instead of jumping
/// (Lawrence 2026-10-18), with no ``MotionClock`` frames and no layout per frame.
///
/// The sidebar lays out in the change's turn and the list's shown bottom edge
/// (``ScrollEdgeFadeView/shownMask``) springs from where it showed: `appear` while the room opens,
/// the quicker `disappear` while it closes, in step with the card's own entrance and exit
/// (``SidebarCardTransition``). A list that shrinks keeps its larger height, clipped at the shown
/// edge, and lays out once more when the spring lands, so its last rows recede under the edge. Rows the clip pushed down
/// (a list scrolled to its end that grows) slide down with the edge. Chrome commits layout once
/// and lets the compositor animate (cc/animation/keyframe_model.h, ui/compositor/layer_animator.h).
///
/// The first layout, a window-less or hidden sidebar and a live resize place at once; the gate
/// decides the rest (Reduce Motion, motion off).
@MainActor
final class SidebarCardSlotMotion {
    /// One layout's room for the slot.
    struct Room: Equatable {
        /// The slot's real height: where the card sits.
        var slot: CGFloat
        /// The slot height the list lays out for: `slot`, or less while the room opens on a spring.
        var list: CGFloat
        /// The slot's height changed in this layout.
        var changed: Bool
        /// The change springs.
        var springs: Bool
        /// How far the list runs under the slot, hidden past its shown edge.
        var hidden: CGFloat { max(0, slot - list) }
    }

    /// The key path the shown edge springs on ``ScrollEdgeFadeView/shownMask``.
    static let edgeKey = RenderSpringKey<CGFloat>.boundsHeight
    /// The key path pushed rows slide on: a translation, which AppKit's frame writes never touch.
    static let pushKey = RenderSpringKey<CGFloat>.translationY

    /// The slot height the last layout placed, nil before the first.
    private(set) var slotHeight: CGFloat?
    /// The slot height the list stays laid out for while the room opens; nil at rest.
    private(set) var heldListRoom: CGFloat?
    /// The list's shown bottom edge after the last layout, in the sidebar's coordinates.
    private var shownEdge: CGFloat?
    private let gate: MotionGate

    /// - Parameter gate: The motion gate the edge obeys (`Motion.overlays`, as the cards).
    init(gate: MotionGate = Motion.overlays) {
        self.gate = gate
    }

    /// The room for a slot whose real height is `slot`, before the sidebar `view` lays out.
    func room(toward slot: CGFloat, in view: NSView) -> Room {
        let last = slotHeight
        slotHeight = slot
        let changed = last.map { $0 != slot } ?? false
        guard let last, animates(in: view) else {
            heldListRoom = nil
            return Room(slot: slot, list: slot, changed: changed, springs: false)
        }
        // Opening: the list keeps the rows it showed until the edge has passed them.
        if slot > last { heldListRoom = min(heldListRoom ?? last, last) }
        if let held = heldListRoom, held >= slot { heldListRoom = nil }
        return Room(slot: slot, list: heldListRoom ?? slot, changed: changed, springs: changed)
    }

    /// The sidebar `view` laid `room` out with the list in `listFrame`. `edge` shows the list,
    /// `document` holds its rows and `scrolled` is how far the list's clip scrolled along its y in
    /// the layout (the clip pushing rows down as the list grew at its end). Returns the frame the
    /// list shows.
    @discardableResult
    func didLayOut(_ room: Room, listFrame: NSRect, edge: ScrollEdgeFadeView, document: NSView, scrolled: CGFloat,
                   in view: NSView) -> NSRect {
        var shown = listFrame
        shown.size.height = max(0, listFrame.height - room.hidden)
        edge.shownHeight = room.hidden > 0 ? shown.height : nil
        let lastEdge = shownEdge
        shownEdge = shown.maxY
        guard room.changed, let lastEdge else { return shown }
        guard room.springs else {
            RenderSpring.stop(edge.shownMask, Self.edgeKey.path)
            if let layer = document.layer { RenderSpring.stop(layer, Self.pushKey.path) }
            return shown
        }
        // With nothing to move the call lands at once and a held list lays out at its real height.
        var moves: [RenderSpring.Move] = []
        if lastEdge != shown.maxY {
            moves.append(RenderSpring.Move(edge.shownMask, Self.edgeKey, from: shown.height + lastEdge - shown.maxY, to: shown.height))
        }
        if scrolled != 0, let layer = document.layer {
            moves.append(RenderSpring.Move(layer, Self.pushKey, from: scrolled, to: CGFloat(0)))
        }
        // The sidebar is flipped: a shown edge higher up than before means the room opened.
        gate.renderSpring(shown.maxY < lastEdge ? .appear : .disappear).animateGroup(moves, in: view) { [weak self, weak view] finished in
            guard finished, let self, self.heldListRoom != nil else { return }
            self.heldListRoom = nil
            view?.needsLayout = true
        }
        return shown
    }

    private func animates(in view: NSView) -> Bool {
        // visibility-walk-allow: this view's motion gate: a hidden view animates nothing and lands at once (no node holds one view's isHidden)
        view.window != nil && !view.inLiveResize && !view.isHiddenOrHasHiddenAncestor
            && gate.renderSpring(.appear).animates(Self.edgeKey.path, in: view)
    }
}
