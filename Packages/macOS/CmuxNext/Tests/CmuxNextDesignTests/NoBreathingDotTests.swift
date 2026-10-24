import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// Leo 2026-10-21, after #22826 made agent work a breathing accent dot on every sidebar row: "who
/// brought back the blinkers!? we had spinners properly going", then "we need to GUARANTEE the
/// breathing dot doesn't come back."
///
/// The rule: agent work is a turning spinner on every surface (sidebar rows, the switcher, hover
/// cards, tabs, web pages). It is never a pulsing, breathing, blinking or opacity-animated dot, in
/// any working look. The breathing look is deleted, not hidden: no `StatusWorkingLook` case, no
/// plan animation, no Motion loop or CAAnimation for it, and a stored `breathe` (a Debug Settings
/// value saved before the deletion) reads as the default, the spinner.
@MainActor @Suite(.serialized) struct NoBreathingDotTests {
    /// One host that draws work, with the exact arguments it passes to `StatusIndicatorPlan.make`.
    struct Host: CustomStringConvertible {
        let description: String
        let plan: (StatusIndicatorState, StatusIndicatorConfig, StatusIndicatorStyle?) -> StatusIndicatorPlan
    }

    static let hosts: [Host] = [
        // StatusIndicatorView.refresh: sidebar rows, the switcher, hover cards.
        Host(description: "StatusIndicatorView") { state, config, hint in
            StatusIndicatorPlan.make(state, style: config.style(hint: hint), animates: true, set: config.iconSet,
                                     isStatic: config.isStatic, staticShapes: config.staticShapes,
                                     working: config.workingLook)
        },
        // TabCell.spinnerPlan (TabCell+StatusIndicator): a tab's busy and working mark.
        Host(description: "TabCell+StatusIndicator") { state, config, hint in
            StatusIndicatorPlan.make(state, style: config.style(hint: hint), animates: config.animatesLoops,
                                     set: config.iconSet, isStatic: config.isStatic,
                                     staticShapes: config.staticShapes, working: config.workingLook)
        },
        // TabCell.statusBadgePlan (TabCell+StatusBadge): the badge never animates.
        Host(description: "TabCell+StatusBadge") { state, config, _ in
            StatusIndicatorPlan.make(state, style: config.settings.style, animates: false, set: config.iconSet,
                                     isStatic: config.isStatic, staticShapes: config.staticShapes,
                                     working: config.workingLook)
        },
    ]

    /// Every style a host may be handed: none (the setting), and each one a report may ask for.
    static let hints: [StatusIndicatorStyle?] = [nil] + StatusIndicatorStyle.allCases.map { $0 }

    /// The states that mean an agent works.
    static let workStates: [StatusIndicatorState] = [.working]

    static func config(_ look: StatusWorkingLook) -> StatusIndicatorConfig {
        StatusIndicatorConfig(iconSet: StatusIconSet.tunable.defaultValue, workingLook: look)
    }

    @Test func theSpinnerIsTheDefaultAndTheOnlyMovingLook() {
        #expect(StatusWorkingLook.tunable.defaultValue == .spinner)
        #expect(StatusWorkingLook.allCases.map(\.rawValue).sorted() == ["shimmer", "spinner"])
    }

    @Test func agentWorkTurnsAsTheSpinnerOnEveryHost() {
        for host in Self.hosts where host.description != "TabCell+StatusBadge" {
            for hint in Self.hints {
                let plan = host.plan(.working, Self.config(.spinner), hint)
                #expect(plan.glyph == .arc && plan.animation == .spin, "\(host) hint \(String(describing: hint)): \(plan)")
            }
        }
    }

    /// The release Loading Indicator choice remains available for users who choose it, while the
    /// default agent-working path keeps the shared spinner even when a style hint is present.
    @Test func pulsingDotRemainsAnExplicitLoadingChoice() {
        #expect(StatusIndicatorStyle.allCases.contains(.dot))
        #expect(StatusIndicatorConfig().settings.style == .arc)
        let busy = StatusIndicatorPlan.make(.busy, style: .dot, animates: true, set: .codex, working: .spinner)
        #expect(busy.glyph == .dot && busy.animation == .pulse)
        let working = StatusIndicatorPlan.make(.working, style: .dot, animates: true, set: .codex, working: .spinner)
        #expect(working.glyph == .arc && working.animation == .spin)
    }

    @Test func noLookMakesAPulsingOrWavingDot() {
        for look in StatusWorkingLook.allCases {
            for host in Self.hosts {
                for hint in Self.hints {
                    for state in Self.workStates {
                        let plan = host.plan(state, Self.config(look), hint)
                        let blinks = plan.animation == .pulse || plan.animation == .wave
                        let dot = plan.glyph == .dot || plan.glyph == .dots
                        #expect(!(blinks && dot), "\(look) \(host) hint \(String(describing: hint)): \(plan)")
                    }
                }
            }
        }
    }

    /// Drawn into the real layer with loops running, no look's work mark loops its opacity, and the
    /// spinner really turns (so the opacity check cannot pass because nothing ran at all).
    @Test func noDrawnWorkMarkLoopsItsOpacityOrScale() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        for look in StatusWorkingLook.allCases {
            for host in Self.hosts {
                for hint in Self.hints {
                    let config = Self.config(look)
                    let indicator = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000 }))
                    indicator.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
                    let plan = host.plan(.working, config, hint)
                    indicator.apply(plan, config: config)
                    let label = "\(look) \(host) hint \(String(describing: hint))"
                    #expect(Self.opacityOrScaleLoops(under: indicator.layer) == [], "\(label)")
                    if look == .spinner, plan.animation != nil {
                        #expect(indicator.runningAnimation == .spin, "\(label)")
                        #expect(Self.rotationLoops(under: indicator.layer) > 0, "\(label): the spinner does not turn")
                    }
                }
            }
        }
    }

    /// A `status.working = "breathe"` saved before the look was deleted reads as the spinner.
    @Test func aStoredBreatheReadsAsTheSpinner() {
        #expect(StatusWorkingLook(rawValue: "breathe") == nil)
        #expect(StatusWorkingLook(tunableValue: .choice("breathe")) == nil)
        let store = TunableStore()
        store.register([StatusWorkingLook.tunable.descriptor])
        store.activate(file: nil)
        store.load(raw: [StatusWorkingLook.tunable.key: "breathe"])
        #expect(StatusWorkingLook.tunable.value(in: store) == .spinner)
        // A set (Debug Settings, the socket) of the old value is the spinner too.
        store.set(StatusWorkingLook.tunable.key, .choice("breathe"))
        #expect(StatusWorkingLook.tunable.value(in: store) == .spinner)
    }

    /// Web pages get the look from the payload; a stored `breathe` sends `spinner`.
    @Test func aStoredBreatheSendsTheSpinnerToWebPages() throws {
        let store = TunableStore.shared
        store.register([StatusWorkingLook.tunable.descriptor])
        store.activate(file: nil)
        let key = StatusWorkingLook.tunable.key
        store.reset([key])
        defer { store.reset([key]) }
        store.load(raw: [key: "breathe"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(WebTheme(.unresolved).payloadJSON.utf8)) as? [String: Any])
        #expect(payload["workingLook"] as? String == "spinner")
    }

    /// The source guard: the breathing look's code never comes back to CmuxNextDesign.
    @Test func theBreathingLookStaysDeleted() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxNextDesign")
        let banned = ["breathAnimation", "case breathe", ".breath"]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for token in banned where text.contains(token) {
                hits.append("\(url.lastPathComponent): \(token)")
            }
        }
        #expect(scanned > 50, "the scan found no sources at \(sources.path)")
        #expect(hits == [], "the breathing dot came back (Leo: \"we need to GUARANTEE the breathing dot doesn't come back\")")
    }

    /// The keys of repeating `opacity` animations on `layer` and the layers under it (masks included).
    static func opacityLoops(under layer: CALayer?) -> [String] {
        loops(under: layer) { $0 == "opacity" }
    }

    /// The working mark may rotate, but never repeats opacity or scale forever.
    static func opacityOrScaleLoops(under layer: CALayer?) -> [String] {
        loops(under: layer) { keyPath in
            keyPath == "opacity" || keyPath?.contains("scale") == true
        }
    }

    /// How many repeating rotations run on `layer` and the layers under it.
    static func rotationLoops(under layer: CALayer?) -> Int {
        loops(under: layer) { $0?.hasPrefix("transform") == true }.count
    }

    private static func loops(under layer: CALayer?, matching keyPath: (String?) -> Bool) -> [String] {
        guard let layer else { return [] }
        let own = (layer.animationKeys() ?? []).filter { key in
            layer.animation(forKey: key).map { repeats($0, matching: keyPath) } == true
        }
        let children = (layer.sublayers ?? []) + [layer.mask].compactMap { $0 }
        return own + children.flatMap { loops(under: $0, matching: keyPath) }
    }

    private static func repeats(_ animation: CAAnimation, matching keyPath: (String?) -> Bool) -> Bool {
        let loops = animation.repeatCount >= .greatestFiniteMagnitude || animation.repeatDuration > 0
        if let group = animation as? CAAnimationGroup {
            return (group.animations ?? []).contains {
                repeats($0, matching: keyPath) || loops && keyPath(($0 as? CAPropertyAnimation)?.keyPath)
            }
        }
        return loops && keyPath((animation as? CAPropertyAnimation)?.keyPath)
    }
}
