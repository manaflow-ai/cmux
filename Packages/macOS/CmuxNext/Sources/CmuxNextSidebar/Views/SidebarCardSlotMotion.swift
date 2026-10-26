import AppKit
import CmuxNextDesign

/// The bottom card slot's room in the sidebar's layout (chrome-parity p03-rendering-033).
///
/// The sidebar lays out once at the slot's real height (`SidebarBottomCardSlot.height`), so
/// every view sits at its rest frame in the change's turn; the card itself plays
/// ``SidebarCardTransition``. The views the slot's change moved (the card stack above it)
/// then slide from where they showed on a render-server spring
/// (``SidebarCardTransition/slide(_:from:opening:gate:in:)``): no ``MotionClock`` frames and no
/// layout per frame. Chrome commits a layout once and lets the compositor animate the layers
/// (cc/animation/keyframe_model.h; ui/compositor/layer_animator.h).
///
/// The first layout, a window-less or hidden sidebar and a live resize place the views
/// without a spring; the gate decides the rest (Reduce Motion, motion off).
@MainActor
final class SidebarCardSlotMotion {
    /// The slot height the last layout placed, nil before the first.
    private(set) var laidOutHeight: CGFloat?
    private let gate: MotionGate

    /// - Parameter gate: The motion gate the slide obeys (`Motion.overlays`).
    init(gate: MotionGate = Motion.overlays) {
        self.gate = gate
    }

    /// The layout placed the slot at `height` and `moved` (views above the slot) at their
    /// rest frames in `view`, the sidebar: they slide from where the last height left them.
    /// Returns how far the slot grew (negative when it shrank; 0 on the first layout).
    @discardableResult
    func slotDidLayOut(height: CGFloat, moved: [NSView], in view: NSView) -> CGFloat {
        defer { laidOutHeight = height }
        guard let last = laidOutHeight, last != height else { return 0 }
        let growth = height - last
        if view.window == nil || view.inLiveResize || view.isHiddenOrHasHiddenAncestor {
            SidebarCardTransition.stopSlide(moved)
        } else {
            // A taller slot moved the views above it up: they start `growth` lower than their rest.
            SidebarCardTransition.slide(moved, from: growth, opening: growth > 0, gate: gate, in: view)
        }
        return growth
    }
}
