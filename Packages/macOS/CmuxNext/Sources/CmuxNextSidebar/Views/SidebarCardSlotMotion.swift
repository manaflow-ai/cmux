import AppKit
import CmuxNextDesign

/// The bottom card slot's height as the list above it lays out: a spring
/// toward the slot's real height (`SidebarBottomCardSlot.height`), so a card
/// that comes in or goes out (the update status after Check for Updates)
/// moves the list's bottom edge smoothly instead of in one jump. The card
/// itself sits at its final place and plays ``SidebarCardTransition``.
///
/// It steps on the window's one ``MotionClock`` and asks for a layout each
/// frame, so every view lays out at its real size (no implicit frame
/// animations). It snaps on the first layout, without a window, under
/// Reduce Motion, with motion off and during a live resize.
@MainActor
final class SidebarCardSlotMotion: MotionAnimating {
    private var height: SpringValue?
    private weak var view: NSView?
    private let policy: @MainActor () -> MotionPolicy

    /// - Parameter policy: The motion settings, read at each change (`Motion.policy`).
    init(policy: @escaping @MainActor () -> MotionPolicy = { Motion.overlays.policy }) {
        self.policy = policy
    }

    /// Whether the height is still moving toward its target.
    var isMoving: Bool { height.map { $0.value != $0.target } ?? false }

    /// The height to lay out now in `view` for a slot whose real height is `target`.
    func height(toward target: CGFloat, in view: NSView) -> CGFloat {
        self.view = view
        guard var height else {
            self.height = SpringValue(target)
            return target
        }
        guard height.target != target else {
            // A spring no clock steps any more (the window's scheduler went inactive and dropped
            // it, `MotionClock.run`) would hold the list short of the card for good (2026-10-20:
            // the Updated card floated over the last rows): it lands on its target.
            if height.value != target, !MotionClock.forView(view).isRunning(self) {
                height.snap()
                self.height = height
            }
            return height.value
        }
        height.target = target
        let animates = policy().animatesMovement && view.window != nil && !view.inLiveResize
            && !view.isHiddenOrHasHiddenAncestor && Motion.canAnimate(in: view)
        if !animates { height.snap() }
        self.height = height
        if animates {
            MotionClock.forView(view).run(self, trace: "sidebar.cardSlot")
        } else {
            MotionClock.forView(view).stop(self)
        }
        return height.value
    }

    /// The window went out of sight: the slot takes its final height now.
    func motionSettle() {
        guard var height else { return }
        height.snap()
        self.height = height
        view?.needsLayout = true
    }

    func motionStep(_ dt: Double) -> Bool {
        guard var height, let view else { return false }
        // Room opens on `appear` and closes on the quicker `disappear`.
        let token: MotionSpring = height.target >= height.value ? .appear : .disappear
        let moving = height.advance(dt, parameters: policy().spring(token), epsilon: 0.25)
        self.height = height
        view.needsLayout = true
        return moving
    }
}
