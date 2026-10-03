import AppKit
import CmuxNextDesign
import QuartzCore

/// Adds a horizontal content transition before profile-scoped rows are
/// replaced. Reduce Motion and disabled animation settings snap.
func animateProfileSwitch(on view: NSView, towardNext: Bool) {
    guard Motion.animatesMovement, let layer = view.layer else { return }
    let transition = CATransition()
    transition.type = .push
    transition.subtype = towardNext ? .fromRight : .fromLeft
    transition.duration = Motion.duration(.screen)
    transition.timingFunction = Motion.fadeCurve
    layer.add(transition, forKey: "cmux.profileSwitch")
}
