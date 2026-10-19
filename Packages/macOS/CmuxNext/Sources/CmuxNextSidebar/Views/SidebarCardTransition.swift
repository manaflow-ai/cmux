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
/// The animations come from `MotionPolicy`'s presentation-only builders, not
/// `Motion.set`, because `Motion.set` writes the model value and reads the
/// global policy.
@MainActor
struct SidebarCardTransition {
    /// The motion settings the card follows (`Motion.policy` by default).
    var policy: MotionPolicy

    init(policy: MotionPolicy = Motion.policy) {
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
        if let fade = policy.fadeAnimation(.fadeIn, "opacity", from: 0, to: 1) {
            layer.add(fade, forKey: Self.opacityKey)
        }
        guard policy.animatesMovement else { return }
        let rise = policy.springAnimation(.appear, "transform.translation.y", from: Self.down(in: view) * Self.travel, to: 0)
        layer.add(rise, forKey: Self.travelKey)
    }

    /// Plays the exit on `view`'s layer and runs `completion` when it ends
    /// (or at once when nothing animates). The card stays drawn until then:
    /// the caller hides it in `completion`.
    func exit(_ view: NSView, completion: @escaping @MainActor @Sendable () -> Void) {
        guard let layer = view.layer, Motion.canAnimate(in: view), !view.isHiddenOrHasHiddenAncestor,
              let opacity = policy.fadeAnimation(.fadeOut, "opacity", from: layer.presentation()?.opacity ?? layer.opacity, to: 0, curve: .easeIn)
        else {
            completion()
            return
        }
        clear(layer)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } // main-proof: committed on main
        opacity.fillMode = .forwards
        opacity.isRemovedOnCompletion = false
        layer.add(opacity, forKey: Self.opacityKey)
        if policy.animatesMovement,
           let drop = policy.fadeAnimation(.fadeOut, "transform.translation.y", from: 0, to: Self.down(in: view) * Self.travel / 2, curve: .easeIn) {
            drop.fillMode = .forwards
            drop.isRemovedOnCompletion = false
            layer.add(drop, forKey: Self.travelKey)
        }
        CATransaction.commit()
    }

    /// Crossfades the next change of `layer`'s contents (a new title, icon or buttons).
    func crossfade(_ layer: CALayer?) {
        guard let layer, let transition = policy.fadeTransition(.crossfade) else { return }
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
