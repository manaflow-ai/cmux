import AppKit
import CmuxNextCompat
import CmuxNextDesignTokens

/// How a toast arrives, restacks and leaves (cx-f6i7). It rises from the
/// window's bottom edge, where toasts live, as it fades in; when a toast
/// below it goes, it slides down to its new slot from where it is on screen;
/// it fades out in place when it ends. A toast replaced by a newer one with
/// its id goes in one frame, so two different toasts never crossfade; the
/// newest one's successor takes its slot in that frame, without arriving.
/// Reduce Motion keeps the fades and drops the movement (`Motion.set` snaps
/// it).
@MainActor
struct CmuxToastMotion {
    /// Fades `toast` in, rising `rise` points to its slot (``CmuxToastTunables/rise``; 0: it only fades).
    /// The toast's style picks the movement (``CmuxToastEntrance``): it rises, grows from 95% about its
    /// center, or slides in from the trailing edge.
    static func appear(_ toast: CmuxToastView, rise: CGFloat) {
        guard let layer = layer(of: toast) else { return }
        Motion.overlays.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
        switch toast.look.entrance {
        case .rise:
            Motion.overlays.set(layer, "transform.translation.y", to: CGFloat(0), spring: .appear, from: downward(toast) * rise)
        case .pop:
            scale(toast, layer, from: popScale, to: 1, spring: .appear)
        case .slide:
            Motion.overlays.set(layer, "transform.translation.x", to: CGFloat(0), spring: .appear, from: slideDistance)
        }
    }

    /// Where a popping toast starts: never from nothing, a visible shape a little smaller.
    static let popScale: CGFloat = 0.95
    /// How far a sliding toast travels in from the trailing edge.
    static let slideDistance: CGFloat = 32

    /// Scales `layer` about the toast's center: AppKit pins a view's layer anchor at its origin, so the
    /// translation moves the origin by the part of the size the scale takes away, on the same spring.
    private static func scale(_ toast: CmuxToastView, _ layer: CALayer, from: CGFloat, to: CGFloat, spring: MotionSpring) {
        let size = toast.bounds.size
        let offset = { (scale: CGFloat) in CGPoint(x: (1 - scale) * size.width / 2, y: (1 - scale) * size.height / 2) }
        Motion.overlays.set(layer, "transform.scale", to: to, spring: spring, from: from)
        Motion.overlays.set(layer, "transform.translation.x", to: offset(to).x, spring: spring, from: offset(from).x)
        Motion.overlays.set(layer, "transform.translation.y", to: offset(to).y, spring: spring, from: offset(from).y)
    }

    /// Runs `relayout`, which moves `toast` to a new frame at once, and
    /// slides it there from where it was drawn.
    static func move(_ toast: CmuxToastView, _ relayout: () -> Void) {
        let before = toast.convert(toast.bounds, to: nil).minY
        relayout()
        let after = toast.convert(toast.bounds, to: nil).minY
        guard abs(after - before) > 0.5, let layer = layer(of: toast) else { return }
        // Window space is y-up; the layer's translation follows its view's flip.
        let shown = (Motion.presentationValue(layer, "transform.translation.y") as? CGFloat) ?? 0
        let offset = (before - after) * (toast.superview?.isFlipped == true ? -1 : 1)
        Motion.overlays.set(layer, "transform.translation.y", to: CGFloat(0), spring: .move, from: shown + offset)
    }

    /// Fades `toast` out, then runs `remove`. `animated` false removes it now,
    /// as does a window off every screen (its fade would never finish).
    static func disappear(_ toast: CmuxToastView, animated: Bool, remove: @escaping @MainActor () -> Void) {
        guard animated, Motion.canAnimate(in: toast), let layer = layer(of: toast), Motion.overlays.duration(.fadeOut) > 0 else { return remove() }
        toast.onHover = nil
        CATransaction.begin()
        CATransaction.setMainCompletion(remove)
        Motion.overlays.set(layer, "opacity", to: Float(0), fade: .fadeOut)
        // Quieter than the entrance: a small nudge the way it came, in the fade's time.
        switch toast.look.entrance {
        case .rise: break
        case .pop: Motion.overlays.set(layer, "transform.scale", to: CGFloat(0.97), movementFade: .fadeOut)
        case .slide: Motion.overlays.set(layer, "transform.translation.x", to: slideDistance / 2, movementFade: .fadeOut)
        }
        CATransaction.commit()
    }

    private static func layer(of toast: CmuxToastView) -> CALayer? {
        toast.wantsLayer = true
        return toast.layer
    }

    /// The sign of "down the screen" for the toast's layer translation.
    private static func downward(_ toast: CmuxToastView) -> CGFloat {
        toast.superview?.isFlipped == true ? 1 : -1
    }
}
