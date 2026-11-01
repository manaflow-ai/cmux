import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// Leo: "GUARANTEE the breathing dot doesn't come back", clarified as "just leave it as an
/// option. just dont make it the default." Guard the default working path, retaining explicit picks.
@MainActor @Suite(.serialized) struct NoBreathingDotTests {
    struct Host: CustomStringConvertible {
        let description: String
        let plan: (StatusIndicatorState, StatusIndicatorConfig, StatusIndicatorStyle?) -> StatusIndicatorPlan
    }

    static let hosts: [Host] = [
        // StatusIndicatorView.refresh: sidebar rows, the switcher and hover cards.
        Host(description: "StatusIndicatorView") { state, config, hint in
            StatusIndicatorPlan.make(state, style: config.style(hint: hint), animates: true, set: config.iconSet,
                                     isStatic: config.isStatic, staticShapes: config.staticShapes,
                                     working: config.workingLook)
        },
        // TabCell.spinnerPlan: a tab's busy and working mark.
        Host(description: "TabCell+StatusIndicator") { state, config, hint in
            StatusIndicatorPlan.make(state, style: config.style(hint: hint), animates: config.animatesLoops,
                                     set: config.iconSet, isStatic: config.isStatic,
                                     staticShapes: config.staticShapes, working: config.workingLook)
        },
        // TabCell.statusBadgePlan: the badge never animates.
        Host(description: "TabCell+StatusBadge") { state, config, _ in
            StatusIndicatorPlan.make(state, style: config.settings.style, animates: false, set: config.iconSet,
                                     isStatic: config.isStatic, staticShapes: config.staticShapes,
                                     working: config.workingLook)
        },
    ]

    @Test func defaultsAreSpinnersAndExplicitPicksAreRetained() {
        #expect(StatusIndicatorSettings().style == .arc)
        #expect(StatusWorkingLook.tunable.defaultValue == .spinner)
        #expect(StatusIndicatorStyle(rawValue: "dot") == .dot)
        #expect(StatusWorkingLook(rawValue: "breathe") == .breathe)
        let store = TunableStore()
        store.register([StatusWorkingLook.tunable.descriptor])
        store.activate(file: nil)
        store.load(raw: [StatusWorkingLook.tunable.key: "breathe"])
        #expect(StatusWorkingLook.tunable.value(in: store) == .breathe)
        let busy = StatusIndicatorPlan.make(.busy, style: .dot, animates: true, set: .codex)
        #expect(busy.glyph == .dot && busy.animation == .pulse)
    }

    @Test func defaultWorkNeverLoopsOpacityOrScaleOnAnyHost() {
        let saved = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = saved }
        let config = StatusIndicatorConfig(iconSet: StatusIconSet.tunable.defaultValue,
                                           workingLook: StatusWorkingLook.tunable.defaultValue)
        let hints: [StatusIndicatorStyle?] = [nil] + StatusIndicatorStyle.allCases.map { $0 }
        for host in Self.hosts {
            for hint in hints {
                let plan = host.plan(.working, config, hint)
                let label = "\(host) hint \(String(describing: hint))"
                #expect(plan.animation == nil || plan.animation == .step, "\(label): \(plan)")
                let indicator = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000 }))
                indicator.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
                indicator.apply(plan, config: config)
                #expect(Self.loops(under: indicator.layer) { $0 == "opacity" || $0?.contains("scale") == true } == [], "\(label)")
                if host.description != "TabCell+StatusBadge" {
                    #expect(plan.glyph == .native && plan.animation == .step, "\(label)")
                    #expect(!Self.loops(under: indicator.layer) { $0 == "transform.rotation.z" }.isEmpty,
                            "\(label): the spinner must actually turn")
                }
                // The terminal state removes every working loop from the real layer tree.
                indicator.apply(.hidden, config: config)
                #expect(Self.loops(under: indicator.layer) { _ in true } == [], "\(label): idle cleanup")
            }
        }
    }

    private static func loops(under layer: CALayer?, matching keyPath: (String?) -> Bool) -> [String] {
        guard let layer else { return [] }
        let own = (layer.animationKeys() ?? []).filter { key in
            layer.animation(forKey: key).map { repeats($0, matching: keyPath) } == true
        }
        let children = (layer.sublayers ?? []) + [layer.mask].compactMap { $0 }
        return own + children.flatMap { loops(under: $0, matching: keyPath) }
    }

    private static func repeats(_ animation: CAAnimation, inherited: Bool = false,
                                matching keyPath: (String?) -> Bool) -> Bool {
        let forever = inherited || animation.repeatCount >= .greatestFiniteMagnitude
            || animation.repeatDuration >= .greatestFiniteMagnitude
        if let group = animation as? CAAnimationGroup {
            return (group.animations ?? []).contains { repeats($0, inherited: forever, matching: keyPath) }
        }
        return forever && keyPath((animation as? CAPropertyAnimation)?.keyPath)
    }
}
