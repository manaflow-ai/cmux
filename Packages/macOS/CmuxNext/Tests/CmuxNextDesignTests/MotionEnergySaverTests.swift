import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeups
import QuartzCore
import Testing

/// Under Energy Saver ambient motion loops hold still and nothing else changes
/// (plans/cmux-next/chrome-parity/p14-energy.md, D; p14-energy-027): the loop helpers return nil,
/// as under Reduce Motion, while moves, fades, the flash verb and the attention blink keep their
/// normal-mode timing. Normal mode is the policy it was before the saver existed.
@MainActor @Suite(.serialized) struct MotionEnergySaverTests {
    /// Runs `body` with the live switches on, Reduce Motion pinned off and the saver set, then puts them back.
    private func with<T>(saver: Bool, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let (oldEnabled, oldDisabled, oldSpeed, oldSaver) = (design.animationsEnabled, design.disabledAnimationCategories,
                                                             design.animationSpeed, design.energySaver)
        Motion.reduceMotionOverride = false
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        design.animationSpeed = .fast
        design.energySaver = saver
        defer {
            design.animationsEnabled = oldEnabled
            design.disabledAnimationCategories = oldDisabled
            design.animationSpeed = oldSpeed
            design.energySaver = oldSaver
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
        try with(saver: true) {
            for category in MotionCategory.allCases {
                let gate = Motion.gate(category)
                #expect(gate.spinAnimation() == nil, "\(category) spins under the saver")
                for (name, loop) in try loops(gate) { #expect(loop == nil, "\(category) \(name) loops under the saver") }
                #expect(!gate.animatesLoops && gate.period(.spinner) == nil && gate.period(.pulse) == nil)
            }
        }
    }

    /// Normal mode is unchanged: every loop runs with the timing and frame rate range it has with no saver input.
    @Test func normalModeLoopsAreUnchanged() throws {
        func shape(_ loop: CAAnimation?) -> [Double] {
            guard let loop else { return [] }
            return [loop.duration, Double(loop.repeatCount), Double(loop.preferredFrameRateRange.maximum)]
        }
        try with(saver: false) {
            let before = try loops(Motion.indicators).map { ($0.0, shape($0.1)) }
            DesignSettings.shared.energySaver = true
            DesignSettings.shared.energySaver = false
            let after = try loops(Motion.indicators).map { ($0.0, shape($0.1)) }
            for ((name, old), (_, new)) in zip(before, after) {
                #expect(!old.isEmpty, "\(name) does not run in normal mode")
                #expect(old == new, "\(name) changed after a saver round trip: \(old) -> \(new)")
            }
            #expect(Motion.indicators.animatesLoops)
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
        }
        #expect(MotionPolicy(speed: .fast, reduceMotion: false).energySaver == false, "the saver input defaults off")
    }

    /// Motion a person or a notification starts keeps its normal-mode shape: the flash verb's two
    /// blinks, the attention blink and its dismiss flash, and a spring a person triggers.
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
            return ["flash": keyframes(flash) + [Float(flash.duration)],
                    "attention": keyframes(attention) + [Float(attention.duration)],
                    "dismiss": keyframes(dismiss) + [Float(dismiss.duration)],
                    "spring": [Float(spring.duration)]]
        }
        let normal = try with(saver: false) { try snapshot() }
        let saver = try with(saver: true) { try snapshot() }
        #expect(normal == saver)
        #expect(normal["flash"].map { Array($0.dropLast()) } == [0, 1, 0, 1, 0], "the flash verb blinks twice")
    }

    /// The composition root's link: the source's saver reaches the gates now and on each change, and a
    /// change raises the motion signal so hosts outside Observation (the video wallpaper) follow.
    @Test func followEnergyCarriesTheSaverToTheGates() {
        let design = DesignSettings(display: { AppearanceSignals.DisplayOptions() })
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .setting))
        var motionSignals = 0
        let watch = design.signals.subscribe([.motion], owner: "MotionEnergySaverTests") { motionSignals += 1 }
        var observation: EnergyPolicyObservation? = design.followEnergy(source)
        #expect(design.energySaver, "the saver at the time of follow")
        #expect(Motion.basePolicy(of: design).energySaver && !Motion.basePolicy(of: design).animatesLoops)
        source.update(.normal)
        #expect(!design.energySaver && Motion.basePolicy(of: design).energySaver == false)
        source.update(EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(design.energySaver)
        #expect(motionSignals == 3, "one motion signal per saver change, got \(motionSignals)")
        observation = nil
        source.update(.normal)
        #expect(design.energySaver, "a released observation wrote the saver off")
        #expect(source.observerCount == 0)
        _ = (watch, observation)
    }
}
