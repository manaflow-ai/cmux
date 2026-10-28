import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeups
import QuartzCore
import Testing

/// Under Energy Saver ambient motion loops hold still and nothing else changes
/// (plans/cmux-next/chrome-parity/p14-energy.md, D): the loop helpers return nil,
/// as under Reduce Motion, while moves, fades, the flash verb, the attention blink and edit mode's
/// wiggle keep their normal-mode timing. Normal mode is the policy it was before the saver existed.
@MainActor @Suite(.serialized) struct MotionEnergySaverTests {
    /// Runs `body` with the live switches on, Reduce Motion pinned off, the saver and frame-rate
    /// pacing (feature `frameRateClasses`) set, then puts them back.
    private func with<T>(saver: Bool, paces: Bool = false, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let (oldEnabled, oldDisabled, oldSpeed, oldSaver) = (design.animationsEnabled, design.disabledAnimationCategories,
                                                             design.animationSpeed, design.energySaver)
        let oldPaces = design.loopsFollowFrameRate
        Motion.reduceMotionOverride = false
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        design.animationSpeed = .fast
        design.energySaver = saver
        design.loopsFollowFrameRate = paces
        defer {
            design.animationsEnabled = oldEnabled
            design.disabledAnimationCategories = oldDisabled
            design.animationSpeed = oldSpeed
            design.energySaver = oldSaver
            design.loopsFollowFrameRate = oldPaces
            Motion.reduceMotionOverride = nil
        }
        return try body()
    }

    private func frames() throws -> [CGImage] {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return Array(repeating: try #require(context.makeImage()), count: 8)
    }

    /// Each loop helper of `gate`, by name (nil where the helper returned none).
    private func loops(_ gate: MotionGate) throws -> [(String, CAAnimation?)] {
        [("spin", gate.spinAnimation()), ("step", gate.stepAnimation(steps: 8)), ("frames", gate.framesAnimation(try frames())),
         ("sweep", gate.sweepAnimation(segment: 10, travel: 100)), ("breath", gate.breathAnimation(low: 0.4)),
         ("pulse", gate.pulseAnimation(low: 0.3))]
    }

    @Test func saverStillsEveryLoop() throws {
        // The same switches with the saver off run every loop of every category, so the nils below
        // are the saver's, not another switch's.
        try with(saver: false) {
            for category in MotionCategory.allCases {
                let gate = Motion.gate(category)
                for (name, loop) in try loops(gate) { #expect(loop != nil, "\(category) \(name) does not loop with the saver off") }
                #expect(gate.animatesLoops && gate.period(.spinner) != nil && gate.period(.pulse) != nil)
            }
        }
        try with(saver: true) {
            for category in MotionCategory.allCases {
                let gate = Motion.gate(category)
                #expect(gate.spinAnimation() == nil, "\(category) spins under the saver")
                for (name, loop) in try loops(gate) { #expect(loop == nil, "\(category) \(name) loops under the saver") }
                #expect(!gate.animatesLoops && gate.period(.spinner) == nil && gate.period(.pulse) == nil)
            }
        }
    }

    /// Normal mode is unchanged: every loop runs forever with its token's period (`MotionLoop`;
    /// a breath and a pulse are two half periods, autoreversed), and asks the render server for the
    /// rate `Motion.paced` gives it: none with pacing off, 30 Hz or its stepping rate with it on.
    @Test func normalModeLoopsAreUnchanged() throws {
        let spinner = MotionLoop.spinner.period
        let expected: [String: (duration: Double, autoreverses: Bool, paced: FrameRate)] = [
            "spin": (spinner, false, .ambient), "step": (spinner, false, .stepping(8, every: spinner)),
            "frames": (spinner, false, .stepping(8, every: spinner)), "sweep": (MotionLoop.sweep.period, false, .ambient),
            "breath": (MotionLoop.breath.period / 2, true, .ambient), "pulse": (MotionLoop.pulse.period / 2, true, .ambient),
        ]
        for paces in [false, true] {
            try with(saver: false, paces: paces) {
                for category in MotionCategory.allCases {
                    for (name, made) in try loops(Motion.gate(category)) {
                        let want = try #require(expected[name])
                        let loop = try #require(made, "\(category) \(name) does not run in normal mode")
                        #expect(loop.duration == want.duration && loop.autoreverses == want.autoreverses, "\(category) \(name) timing")
                        #expect(loop.repeatCount == .infinity, "\(category) \(name) stops")
                        let range = paces ? want.paced.range : CAFrameRateRange.default
                        let asked = loop.preferredFrameRateRange
                        #expect(asked.minimum == range.minimum && asked.maximum == range.maximum && asked.preferred == range.preferred,
                                "\(category) \(name) asks for \(loop.preferredFrameRateRange), not \(range) (pacing \(paces))")
                    }
                }
            }
        }
    }

    /// The saver changes only loops: moves, fades, durations and springs read as in normal mode.
    @Test func saverLeavesEverythingButLoops() {
        let normal = MotionPolicy(speed: .fast, reduceMotion: false, enabledKinds: [.newTab], pacesLoops: true)
        var saver = normal
        saver.energySaver = true
        for category in MotionCategory.allCases {
            let (off, on) = (normal.for(category), saver.for(category))
            #expect(off.animatesLoops && !on.animatesLoops, "\(category)")
            #expect(on.animatesMovement == off.animatesMovement && on.animatesFades == off.animatesFades
                && on.animatesBlinks == off.animatesBlinks && on.animates(.newTab) == off.animates(.newTab))
            #expect(on.duration(MotionFade.fadeIn) == off.duration(MotionFade.fadeIn)
                && on.duration(MotionFade.hover) == off.duration(MotionFade.hover)
                && on.duration(MotionSpring.move) == off.duration(MotionSpring.move)
                && on.spring(.move) == off.spring(.move))
            #expect(on.period(.spinner) == nil && off.period(.spinner) == MotionLoop.spinner.period)
            // The loops that follow the person keep their period (the flash, edit mode's wiggle).
            for loop in MotionLoop.allCases where !loop.isAmbient {
                #expect(on.period(loop) == loop.period && off.period(loop) == loop.period, "\(category) \(loop) stops under the saver")
            }
        }
        #expect(MotionPolicy(speed: .fast, reduceMotion: false).energySaver == false, "the saver input defaults off")
        #expect(MotionLoop.allCases.filter { !$0.isAmbient } == [.flash, .wiggle], "a loop changed sides: classify it on purpose")
    }

    /// Motion a person or a notification starts keeps its normal-mode shape: the flash verb's two
    /// blinks, the attention blink and its dismiss flash, edit mode's wiggle (the mode the person
    /// entered; its wiggle is the sign it is on) and a spring a person triggers.
    @Test func personStartedMotionIsUnchanged() throws {
        func keyframes(_ animation: CAAnimation?) -> [Float] {
            ((animation as? CAKeyframeAnimation)?.values ?? []).compactMap { ($0 as? NSNumber)?.floatValue }
        }
        var blinkSettings = AttentionSettings()
        blinkSettings.style = .blink
        func snapshot() throws -> [String: [Float]] {
            let gate = Motion.indicators
            let flash = try #require(gate.flashAnimation())
            let attention = try #require(gate.attentionAnimation(blinkSettings, look: .subtle))
            let dismiss = try #require(gate.attentionDismissAnimation(AttentionSettings(), look: .subtle))
            let layer = CALayer()
            let spring = try #require(Motion.panes.set(layer, "position", to: CGPoint(x: 40, y: 0), spring: .move, from: CGPoint.zero))
            let wiggle = try #require(Motion.sidebar.wiggleAnimation(center: CGPoint(x: 20, y: 10), phase: 0.25) as? CAKeyframeAnimation)
            return ["flash": keyframes(flash) + [Float(flash.duration)],
                    "attention": keyframes(attention) + [Float(attention.duration)],
                    "dismiss": keyframes(dismiss) + [Float(dismiss.duration)],
                    "spring": [Float(spring.duration)],
                    "wiggle": [Float(wiggle.values?.count ?? 0), Float(wiggle.duration), Float(wiggle.timeOffset), Float(wiggle.repeatCount)]]
        }
        let normal = try with(saver: false) { try snapshot() }
        let saver = try with(saver: true) { try snapshot() }
        #expect(normal == saver)
        #expect(normal["wiggle"]?.first == 3, "edit mode's wiggle turns either way and back")
        #expect(normal["flash"].map { Array($0.dropLast()) } == [0, 1, 0, 1, 0], "the flash verb blinks twice")
    }

    /// The composition root's link (MotionEnergyLink): the source's saver reaches the gates now and on each change, and a
    /// change raises the motion signal so hosts outside Observation (the video wallpaper) follow.
    @Test func theLinkCarriesTheSaverToTheGates() {
        let design = DesignSettings(display: { AppearanceSignals.DisplayOptions() })
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .setting))
        var motionSignals = 0
        let watch = design.signals.subscribe([.motion], owner: "MotionEnergySaverTests") { motionSignals += 1 }
        var link: MotionEnergyLink? = MotionEnergyLink(source, design: design)
        #expect(design.energySaver, "the saver when the link is made")
        #expect(Motion.basePolicy(of: design).energySaver && !Motion.basePolicy(of: design).animatesLoops)
        source.update(.normal)
        #expect(!design.energySaver && Motion.basePolicy(of: design).energySaver == false)
        source.update(EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(design.energySaver)
        #expect(motionSignals == 3, "one motion signal per saver change, got \(motionSignals)")
        link = nil
        source.update(.normal)
        #expect(design.energySaver, "a released link wrote the saver off")
        #expect(source.observerCount == 0)
        _ = (watch, link)
    }
}
