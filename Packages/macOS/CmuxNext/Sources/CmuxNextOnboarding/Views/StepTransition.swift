import AppKit
import CmuxNextDesign

/// Step changes, through Motion tokens: a crossfade, a short slide with a
/// fade in the direction of travel, or nothing. Nothing bounces. Reduce
/// Motion turns the slide into the fade; animations off: no animation.
@MainActor
enum StepTransition {
    static let slideDistance: CGFloat = 24

    static func reveal(_ view: NSView, transition: OnboardingTransition, forward: Bool) {
        guard transition != .none else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        Motion.set(layer, "opacity", to: Float(1), fade: .crossfade, from: Float(0))
        guard transition == .slide, Motion.animatesMovement else { return }
        let offset = NSValue(caTransform3D: CATransform3DMakeTranslation(forward ? slideDistance : -slideDistance, 0, 0))
        Motion.set(layer, "transform", to: NSValue(caTransform3D: CATransform3DIdentity), fade: .crossfade, from: offset)
    }
}
