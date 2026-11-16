#if canImport(UIKit)
import UIKit

// Reduce Motion for the conversation's UIKit animations. With it on, spatial
// motion (position, scale, transform, springs, sliding panels) lands in its
// end state at once and decorative loops don't start; opacity crossfades
// stay, since a crossfade is Apple's recommended reduced form (each one is
// marked `motion: allow crossfade` where it is called).

extension UIView {
    /// True while Settings > Accessibility > Motion > Reduce Motion is on.
    static var reducesMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// `UIView.animate(withDuration:delay:options:animations:completion:)`,
    /// or with Reduce Motion on the end state at once.
    static func animateUnlessReduceMotion(
        withDuration duration: TimeInterval,
        delay: TimeInterval = 0,
        options: UIView.AnimationOptions = [],
        animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !reducesMotion else { return land(options: options, animations, completion: completion) }
        UIView.animate(withDuration: duration, delay: delay, options: options, animations: animations, completion: completion)
    }

    /// `UIView.animate(withDuration:delay:usingSpringWithDamping:...)`, or
    /// with Reduce Motion on the end state at once.
    static func animateUnlessReduceMotion(
        withDuration duration: TimeInterval,
        delay: TimeInterval,
        usingSpringWithDamping damping: CGFloat,
        initialSpringVelocity velocity: CGFloat,
        options: UIView.AnimationOptions = [],
        animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !reducesMotion else { return land(options: options, animations, completion: completion) }
        UIView.animate(
            withDuration: duration, delay: delay, usingSpringWithDamping: damping, initialSpringVelocity: velocity,
            options: options, animations: animations, completion: completion
        )
    }

    /// `UIView.animate(springDuration:bounce:...)`, or with Reduce Motion on
    /// the end state at once.
    static func animateUnlessReduceMotion(
        springDuration duration: TimeInterval = 0.5,
        bounce: CGFloat = 0,
        initialSpringVelocity velocity: CGFloat = 0,
        delay: TimeInterval = 0,
        options: UIView.AnimationOptions = [],
        animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !reducesMotion else { return land(options: options, animations, completion: completion) }
        UIView.animate(
            springDuration: duration, bounce: bounce, initialSpringVelocity: velocity, delay: delay,
            options: options, animations: animations, completion: completion
        )
    }

    /// Applies `animations` with no animation (an enclosing animation, such
    /// as a keyboard notification's, included). It goes through a
    /// zero-length UIKit animation so UIKit calls `completion` with true the
    /// way it does for any animation that ends at once: after the caller's
    /// own code, as an animated completion would run, so ordering holds.
    private static func land(options: UIView.AnimationOptions, _ animations: @escaping () -> Void, completion: ((Bool) -> Void)?) {
        UIView.animate(
            withDuration: 0, delay: 0, options: options.subtracting([.repeat, .autoreverse]),
            animations: { UIView.performWithoutAnimation(animations) }, completion: completion
        )
    }
}
#endif
