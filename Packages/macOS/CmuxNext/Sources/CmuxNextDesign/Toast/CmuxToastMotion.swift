import AppKit

/// How a toast arrives, restacks and leaves (cx-f6i7). It rises from the
/// window's bottom edge, where toasts live, as it fades in; when a toast
/// below it goes, it slides down to its new slot from where it is on screen;
/// it fades out in place when it ends. A toast replaced by a newer one with
/// its id goes in one frame, so two different toasts never crossfade.
/// Reduce Motion keeps the fades and drops the movement (`Motion.set` snaps
/// it).
@MainActor
enum CmuxToastMotion {
    /// How far below its slot a new toast starts.
    static let rise: CGFloat = 8

    static func appear(_ toast: CmuxToastView) {
        guard let layer = layer(of: toast) else { return }
        Motion.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
        Motion.set(layer, "transform.translation.y", to: CGFloat(0), spring: .appear, from: downward(toast) * rise)
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
        Motion.set(layer, "transform.translation.y", to: CGFloat(0), spring: .move, from: shown + offset)
    }

    /// Fades `toast` out, then runs `remove`. `animated` false removes it now,
    /// as does a window off every screen (its fade would never finish).
    static func disappear(_ toast: CmuxToastView, animated: Bool, remove: @escaping @MainActor () -> Void) {
        guard animated, Motion.canAnimate(in: toast), let layer = layer(of: toast), Motion.duration(.fadeOut) > 0 else { return remove() }
        toast.onHover = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { remove() } // main-proof: CATransaction.h: the completion block is called on the main thread
        }
        Motion.set(layer, "opacity", to: Float(0), fade: .fadeOut)
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
