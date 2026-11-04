#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// Tells whether a Core Animation commit happened between ``arm()`` and ``committed`` (FRAME OWNER REFACTOR S7, DEBUG and
/// bench builds: does AppKit commit a window's new size inside the `setFrame` of a live resize?). It changes a hidden
/// layer's opacity in the open transaction; a layer's presentation copy takes a value only when a transaction carrying it
/// commits, so the presentation showing the new value means a commit happened since.
@MainActor
final class CommitWitness {
    /// The witness layer, a hidden sublayer of a layer in the window's tree (`attach(to:)`).
    let layer = CALayer()
    private var armed: Float = 0

    init() {
        // No implicit animation: the presentation takes the value at the commit, not over an animation, and the value
        // joins the open (implicit) transaction instead of an explicit one whose commit would flush it.
        layer.actions = ["opacity": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer.isHidden = true
        layer.frame = .zero
    }

    /// Puts the witness layer under `parent` (once).
    func attach(to parent: CALayer) {
        guard layer.superlayer !== parent else { return }
        layer.removeFromSuperlayer()
        parent.addSublayer(layer)
    }

    /// Marks the open transaction with a new value.
    func arm() {
        armed = armed == 0.5 ? 0.25 : 0.5
        layer.opacity = armed
    }

    /// Whether a commit carried the value ``arm()`` set.
    var committed: Bool { layer.presentation()?.opacity == armed }
}
#endif
