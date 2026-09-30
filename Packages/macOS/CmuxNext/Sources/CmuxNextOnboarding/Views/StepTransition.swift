import AppKit
import CmuxNextDesign

/// Step and page changes: the new content fades in while sliding a short
/// distance in the direction of travel (Motion `appear` + `fadeIn`); the old
/// content is gone in the same frame. Under Reduce Motion only the fade
/// runs; with animations off, nothing animates.
@MainActor
enum StepTransition {
    static func reveal(_ view: NSView, forward: Bool, distance: CGFloat = OnboardingMetrics.slideDistance) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        Motion.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
        let offset = NSValue(caTransform3D: CATransform3DMakeTranslation(forward ? distance : -distance, 0, 0))
        Motion.set(layer, "transform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .appear, from: offset)
    }
}
