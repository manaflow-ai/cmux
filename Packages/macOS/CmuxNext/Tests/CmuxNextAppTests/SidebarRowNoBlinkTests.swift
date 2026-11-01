import AppKit
@testable import CmuxNextDesign
import Testing

/// Leo 2026-10-21: "WHO BROUGHT BACK BLINKING ICONS? WE SAID NO BLINKING. WE SAID SPINNER." (#22826
/// made agent work a breathing dot on every row.) At the defaults no sidebar row's status mark pulses,
/// breathes or waves: running turns as the spinner, and every other state holds still.
@MainActor struct SidebarRowNoBlinkTests {
    private static let states: [StatusIndicatorState] = [
        .idle, .working, .busy, .paused(progress: nil), .waiting, .waiting(kind: .permission), .waiting(kind: .question),
        .error, .success,
    ]

    /// A row's mark for `state` at the default settings, with loops on (a visible window).
    private static func plan(_ state: StatusIndicatorState) -> StatusIndicatorPlan {
        StatusIndicatorPlan.make(state, style: StatusIndicatorSettings().style, animates: true,
                                 set: StatusIconSet.tunable.defaultValue, working: StatusWorkingLook.tunable.defaultValue)
    }

    @Test func runningTurnsAsTheSpinner() {
        #expect(Self.plan(.working) == StatusIndicatorPlan.working(tint: .spinner))
    }

    @Test func noMarkBlinks() {
        let blinks: [StatusIndicatorPlan.Animation] = [.pulse, .breathe, .wave]
        for state in Self.states {
            let animation = Self.plan(state).animation
            #expect(animation.map(blinks.contains) != true, "\(state) draws \(String(describing: animation))")
        }
    }

    /// Drawn: no layer of any mark carries a repeating opacity animation.
    @Test func noDrawnMarkLoopsItsOpacity() {
        let config = StatusIndicatorConfig(iconSet: StatusIconSet.tunable.defaultValue,
                                           workingLook: StatusWorkingLook.tunable.defaultValue)
        for state in Self.states {
            let indicator = StatusIndicatorLayer()
            indicator.layer.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
            indicator.apply(Self.plan(state), config: config)
            #expect(Self.opacityLoops(under: indicator.layer) == [], "\(state)")
        }
    }

    /// The keys of repeating animations of `opacity` on `layer` and the layers under it (masks included).
    static func opacityLoops(under layer: CALayer?) -> [String] {
        guard let layer else { return [] }
        let own = (layer.animationKeys() ?? []).filter { key in
            layer.animation(forKey: key).map(pulses) == true
        }
        return own + ((layer.sublayers ?? []) + [layer.mask].compactMap { $0 }).flatMap { opacityLoops(under: $0) }
    }

    private static func pulses(_ animation: CAAnimation) -> Bool {
        if let group = animation as? CAAnimationGroup {
            let repeats = group.repeatCount >= .greatestFiniteMagnitude || group.repeatDuration > 0
            return (group.animations ?? []).contains { pulses($0) || repeats && ($0 as? CAPropertyAnimation)?.keyPath == "opacity" }
        }
        let repeats = animation.repeatCount >= .greatestFiniteMagnitude || animation.repeatDuration > 0
        return repeats && (animation as? CAPropertyAnimation)?.keyPath == "opacity"
    }
}
