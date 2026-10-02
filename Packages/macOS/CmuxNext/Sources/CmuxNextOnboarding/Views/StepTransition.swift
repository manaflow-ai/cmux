import AppKit
import CmuxNextDesign

/// Step changes: the new content fades in (Motion `crossfade`); nothing
/// moves or bounces. Reduce Motion and animations off: no animation.
@MainActor
enum StepTransition {
    static func reveal(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        Motion.set(layer, "opacity", to: Float(1), fade: .crossfade, from: Float(0))
    }
}
