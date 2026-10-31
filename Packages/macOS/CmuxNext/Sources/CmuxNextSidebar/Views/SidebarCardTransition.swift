import AppKit
import CmuxNextDesign
import QuartzCore

/// How a bottom-left card (the update status notice, the staged update card)
/// comes in, goes out and swaps what it says (Lawrence 2026-10-18: "the check
/// for updates thing needs better animations for both coming in and coming
/// out").
///
/// In: a `fadeIn` fade and an 8 pt rise on the `appear` spring. Out: a
/// quicker `fadeOut` fade and a 4 pt drop on an ease-in curve, so it leaves
/// faster than it came. A content change (Checking… to Up to Date) is a
/// `crossfade` instead of a pop. Under Reduce Motion the card only fades;
/// with motion speed off nothing animates. Every animation is presentation
/// only: the layer's model values never change, so layout never sees them.
///
/// The Core Animation objects are built here, not through `Motion.set`, because
/// `Motion.set` writes the model value and reads the global policy. The fade
/// durations and the spring's stiffness and damping come from `policy` tokens; the
/// easing curves (ease-out in, ease-in out) and the spring's 0.002 settle tolerance
/// (as `Motion.springAnimation`) are literal (check-motion `motion-allow`, pending
/// the owner's call on a port to the Motion helpers).
@MainActor
struct SidebarCardTransition {
    /// The motion settings the card follows (`Motion.policy` by default).
    var policy: MotionPolicy

    init(policy: MotionPolicy = Motion.overlays.policy) {
        self.policy = policy
    }

    /// The animation keys this type adds to a card's layer.
    static let opacityKey = "cmux.card.opacity", travelKey = "cmux.card.travel", crossfadeKey = "cmux.card.crossfade"
    /// How far the card rises on its way in.
    static let travel: CGFloat = 8

    /// Plays the entrance on `view`'s layer.
    func enter(_ view: NSView) {
        guard let layer = view.layer, Motion.canAnimate(in: view) else { return }
        clear(layer)
        let fade = policy.duration(.fadeIn)
        if fade > 0 {
            let animation = CABasicAnimation(keyPath: "opacity") // motion-allow: policy tokens (type doc)
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = fade
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut) // motion-allow: policy tokens (type doc)
            layer.add(animation, forKey: Self.opacityKey)
        }
        guard policy.animatesMovement else { return }
        let spring = policy.spring(.appear)
        let animation = CASpringAnimation(keyPath: "transform.translation.y") // motion-allow: policy tokens (type doc)
        animation.mass = 1
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.duration = spring.settlingTime(within: 0.002) // motion-allow: policy tokens (type doc)
        animation.fromValue = Self.down(in: view) * Self.travel
        animation.toValue = 0
        layer.add(animation, forKey: Self.travelKey)
    }

    /// Plays the exit on `view`'s layer and runs `completion` when it ends
    /// (or at once when nothing animates). The card stays drawn until then:
    /// the caller hides it in `completion`.
    func exit(_ view: NSView, completion: @escaping @MainActor @Sendable () -> Void) {
        let fade = policy.duration(.fadeOut)
        guard let layer = view.layer, fade > 0, Motion.canAnimate(in: view), !view.isHiddenOrHasHiddenAncestor else {
            completion()
            return
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        clear(layer)
        let curve = CAMediaTimingFunction(name: .easeIn) // motion-allow: policy tokens (type doc)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } // main-proof: committed on main
        let opacity = CABasicAnimation(keyPath: "opacity") // motion-allow: policy tokens (type doc)
        opacity.fromValue = from
        opacity.toValue = 0
        opacity.duration = fade
        opacity.timingFunction = curve
        opacity.fillMode = .forwards
        opacity.isRemovedOnCompletion = false
        layer.add(opacity, forKey: Self.opacityKey)
        if policy.animatesMovement {
            let drop = CABasicAnimation(keyPath: "transform.translation.y") // motion-allow: policy tokens (type doc)
            drop.fromValue = 0
            drop.toValue = Self.down(in: view) * Self.travel / 2
            drop.duration = fade
            drop.timingFunction = curve
            drop.fillMode = .forwards
            drop.isRemovedOnCompletion = false
            layer.add(drop, forKey: Self.travelKey)
        }
        CATransaction.commit()
    }

    /// Crossfades the next change of `layer`'s contents (a new title, icon or buttons).
    func crossfade(_ layer: CALayer?) {
        let duration = policy.duration(.crossfade)
        guard let layer, duration > 0 else { return }
        let transition = CATransition() // motion-allow: policy tokens (type doc)
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut) // motion-allow: policy tokens (type doc)
        layer.add(transition, forKey: Self.crossfadeKey)
    }

    /// Removes the entrance and exit animations (a card that comes back mid-exit).
    func clear(_ layer: CALayer?) {
        layer?.removeAnimation(forKey: Self.opacityKey)
        layer?.removeAnimation(forKey: Self.travelKey)
    }

    /// +1 when a positive y moves `view` down on screen: its layer lives in
    /// its superview's layer, flipped when the superview is.
    static func down(in view: NSView) -> CGFloat {
        (view.superview?.isFlipped ?? true) ? 1 : -1
    }
}
