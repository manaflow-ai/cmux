import AppKit
import CmuxNextDesign

/// A node's `transition` (`opacity`, `slide`, `scale`, `move`): how it comes in when a render adds it
/// after its parent's first frame, and goes out when a render removes it, as SwiftUI's transitions.
/// Every change runs through the sidebar motion gate: Reduce Motion keeps only the fade (a
/// crossfade), and motion off adds and removes the node at once.
extension AppSceneNodeNSView {
    /// The node's transition, nil when it has none.
    var sceneTransition: String? {
        switch node.string("transition") {
        case "opacity", "slide", "scale", "move": node.string("transition")
        default: nil
        }
    }

    /// How far a sliding or moving node travels, in points.
    private static let travel: CGFloat = 12
    /// Where a scaling node starts and ends.
    private static let shrunk: CGFloat = 0.85

    /// The keyPath and the off-screen value of the transition's movement, nil for `opacity`.
    private var movement: (keyPath: String, away: CGFloat, rest: CGFloat)? {
        switch sceneTransition {
        // From the leading edge (the view is flipped; x grows to the trailing side).
        case "slide": ("transform.translation.x", -Self.travel, 0)
        // From below, as SwiftUI's default `move(edge: .bottom)`.
        case "move": ("transform.translation.y", Self.travel, 0)
        case "scale": ("transform.scale", Self.shrunk, 1)
        default: nil
        }
    }

    /// The node comes in: it fades up to its opacity and moves from off its place.
    func transitionIn() {
        isLeaving = false
        let target = node.number("opacity").map { CGFloat(min(max($0, 0), 1)) } ?? 1
        alphaValue = 0
        Motion.sidebar.animate(.fadeIn, in: self, { animator().alphaValue = target })
        if let layer, let movement {
            Motion.sidebar.set(layer, movement.keyPath, to: movement.rest, movementFade: .fadeIn, from: movement.away)
        }
    }

    /// The node goes out: it fades and moves off, then `removed` runs (at once with motion off).
    func transitionOut(_ removed: @escaping @MainActor @Sendable () -> Void) {
        isLeaving = true
        if let layer, let movement {
            Motion.sidebar.set(layer, movement.keyPath, to: movement.away, movementFade: .fadeOut)
        }
        Motion.sidebar.animate(.fadeOut, in: self, { animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, self.isLeaving else { return }
            self.isLeaving = false
            removed()
            // A node kept for its next insert starts from rest.
            if self.movement != nil, let layer = self.layer { Motion.sidebar.withoutAnimation { layer.transform = CATransform3DIdentity } }
        })
    }

    /// Ends an exit at once: the node shows at its opacity and place, with no animation (it came
    /// back with no entrance to run). Every movement is a transform sub-key, and a node sets no
    /// transform of its own, so rest is the identity.
    func settleAtRest() {
        isLeaving = false
        let target = node.number("opacity").map { CGFloat(min(max($0, 0), 1)) } ?? 1
        layer?.removeAllAnimations()
        Motion.sidebar.withoutAnimation {
            alphaValue = target
            layer?.transform = CATransform3DIdentity
        }
    }
}
