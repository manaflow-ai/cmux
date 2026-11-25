public import AppKit

/// In-place content transitions of a ``MotionGate``: a value that changes where it stands, as a
/// widget's big number (an app scene's `contentTransition: "numericText"`).
extension MotionGate {
    /// Rolls `layer`'s next contents in: up when the value grew (`upward`), down when it shrank, as
    /// SwiftUI's numeric text transition. Under Reduce Motion it crossfades in place (motion.md rule 7);
    /// with the category, the master switch or the speed off it changes at once. Returns the added
    /// transition, or nil when the change applies at once.
    @discardableResult
    public func rollInPlace(_ layer: CALayer?, upward: Bool) -> CATransition? {
        guard let layer else { return nil }
        guard animatesMovement(in: Motion.window(showing: layer)) else { return crossfadeInPlace(layer) }
        let seconds = duration(.fadeIn)
        guard seconds > 0 else { return nil }
        let transition = Motion.pushUpAction
        transition.subtype = upward ? .fromBottom : .fromTop
        transition.duration = seconds
        transition.timingFunction = fadeCurve
        layer.add(transition, forKey: "cmux.contentRoll")
        return transition
    }
}
