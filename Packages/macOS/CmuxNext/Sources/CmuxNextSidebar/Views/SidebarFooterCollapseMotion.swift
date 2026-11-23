import AppKit
import CmuxNextDesign

/// How much of the sidebar's bottom chrome the workspace list takes over, as the list lays out
/// (Lawrence 2026-11-15, msg 34327: "for minimal mode there is more space at bottom we can use when mouse is not
/// hovered in sidebar, we can do height animation of bottom area too"). In Minimal Mode, with the pointer away,
/// the footer (profile control, spaces, Search) is faded out, so its height goes to the list; the pointer over the
/// sidebar gives it back. The height moves with the footer's fade: the hover fade's duration (`.hover` in the
/// `feedback` category, so speed, the category switch and Reduce Motion apply) on the same ease-out curve
/// (`Motion.fadeCurve`), so the room opens as the controls go and closes as they come. The footer itself keeps
/// its frame and fades in place (``SidebarChromeReveal``); the list, the band below it and the cards move.
///
/// It steps on the window's one ``MotionClock`` and asks for a layout each frame, so every view lays out at its
/// real size (no implicit frame animation). A new target starts from the height on screen (interruptible). It
/// snaps on the first layout, without a window or screen, with motion off and during a live resize.
@MainActor
final class SidebarFooterCollapseMotion: MotionAnimating {
    private var value: CGFloat?
    private var from: CGFloat = 0
    private var target: CGFloat = 0
    private var elapsed: Double = 0
    private var duration: Double = 0
    private weak var view: NSView?

    /// The height to give the list now in `view`, moving toward `target`.
    func height(toward target: CGFloat, in view: NSView) -> CGFloat {
        self.view = view
        guard let value else {
            (self.value, self.target) = (target, target)
            return target
        }
        guard target != self.target else {
            // A clock that dropped this (its scheduler went inactive) must not leave the list between heights.
            if value != target, !MotionClock.forView(view).isRunning(self) {
                self.value = target
                return target
            }
            return value
        }
        let seconds = Motion.feedback.duration(.hover)
        let animates = seconds > 0 && Motion.feedback.animatesFades && Motion.feedback.canAnimate(in: view)
            && view.window != nil && !Motion.isLiveResizing(view.window) && !view.isHiddenOrHasHiddenAncestor
        (from, self.target, elapsed, duration) = (value, target, 0, seconds)
        guard animates else {
            self.value = target
            MotionClock.forView(view).stop(self)
            return target
        }
        MotionClock.forView(view).run(self, trace: "sidebar.footerCollapse")
        return value
    }

    func motionStep(_ dt: Double) -> Bool {
        guard let view else { return false }
        elapsed += dt
        let t = duration > 0 ? min(1, elapsed / duration) : 1
        value = from + (target - from) * Self.easeOut(t)
        view.needsLayout = true
        return t < 1
    }

    func motionSettle() {
        value = target
        view?.needsLayout = true
    }

    /// `Motion.fadeCurve` (ease-out, control points 0, 0, 0.58, 1) at progress `t`: the curve the footer's fade runs.
    static func easeOut(_ t: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        let (x1, y1, x2, y2) = (0.0, 0.0, 0.58, 1.0)
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
        }
        // Solve x(s) = t by bisection (x is monotonic on [0, 1]); 20 steps is below a point at any sidebar height.
        var (lo, hi) = (0.0, 1.0)
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if bezier(mid, x1, x2) < t { lo = mid } else { hi = mid }
        }
        return CGFloat(bezier((lo + hi) / 2, y1, y2))
    }
}
