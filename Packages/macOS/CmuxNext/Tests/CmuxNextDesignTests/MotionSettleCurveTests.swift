import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
import CmuxNextDesignTokens

/// The settle, the native copy of the webviews' `--cmux-ease-settle` (Leo 2026-11-07, of a reference
/// panel's folds: "they dont overshoot but they decelerate at the end. i think that might be the
/// key"; of the measured curve: "this is the new system"). It is generated from
/// schemas/motion-scale/motion-scale.json into `MotionScale`, runs as `MotionCurve.settle` through a
/// motion gate, and obeys the master switch, the category switch, `ui.animationSpeed` and Reduce
/// Motion as every other movement does. These read the code defaults, not a Debug Settings override.
@MainActor @Suite(.serialized, .closesItsWindows) struct MotionSettleCurveTests {
    private func policy(enabled: Bool = true, disabled: Set<MotionCategory> = [], reduceMotion: Bool = false,
                        speed: MotionSpeed = .fast, liveResize: Bool = false) -> MotionPolicy {
        MotionPolicy(speed: speed, reduceMotion: reduceMotion, liveResize: liveResize, animationsEnabled: enabled,
                     disabledCategories: disabled, category: .home)
    }

    /// Runs `body` with the live switches set, then puts them back (MotionMasterSwitchSurfaceTests' pattern).
    private func with(enabled: Bool = true, disabled: Set<MotionCategory> = [], reduceMotion: Bool = false,
                      speed: MotionSpeed = .fast, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let (oldEnabled, oldDisabled, oldSpeed) = (design.animationsEnabled, design.disabledAnimationCategories, design.animationSpeed)
        Motion.reduceMotionOverride = reduceMotion
        design.animationSpeed = speed
        design.animationsEnabled = enabled
        design.disabledAnimationCategories = disabled
        defer {
            design.animationsEnabled = oldEnabled
            design.disabledAnimationCategories = oldDisabled
            design.animationSpeed = oldSpeed
            Motion.reduceMotionOverride = nil
        }
        try body()
    }

    /// The token's values: the measured 265 ms on cubic-bezier(0.16, 1, 0.3, 1), from the generated scale.
    @Test func theTokenIsTheMeasuredLengthAndCurve() throws {
        #expect(MotionScale.settle == 0.265)
        let (x1, y1, x2, y2) = MotionScale.settleCurve
        #expect([x1, y1, x2, y2] == [0.16, 1, 0.3, 1])
        #expect(try #require(MotionTunables.curveDefaults[.settle]?.0) == MotionScale.settle)
        #expect(MotionCurve.settle.baseDuration == MotionScale.settle)
        let (cx1, cy1, cx2, cy2) = MotionCurve.settle.controlPoints
        #expect([cx1, cy1, cx2, cy2] == [x1, y1, x2, y2])
        // Every Motion tunable reaches Debug Settings, the curve's too.
        #expect(MotionTunables.all.contains { $0.key == "motion.curve.settle" })
        // Core Animation and AppKit run the same curve.
        var points: [Float] = [0, 0]
        let function = Motion.timingFunction(.settle)
        function.getControlPoint(at: 1, values: &points)
        #expect(points == [0.16, 1])
        function.getControlPoint(at: 2, values: &points)
        #expect(points == [0.3, 1])
    }

    /// The shape: at full speed from the first frame and decelerating into its end, never past it, within a
    /// few percent of the recording's 1 - e^(-t / 38 ms). A critically damped spring starts from rest instead.
    @Test func theCurveStartsAtFullSpeedAndNeverOvershoots() {
        let seconds = MotionScale.settle
        var previous = 0.0
        for millisecond in 1...265 {
            let t = Double(millisecond) / 1000
            let value = TimedProgress.progress(at: t / seconds, curve: .settle)
            #expect(value <= 1 + 1e-9, "past its end at \(millisecond) ms")
            #expect(value >= previous - 1e-9, "turned back at \(millisecond) ms")
            #expect(abs(value - (1 - exp(-t / 0.038))) < 0.03, "off the measured curve at \(millisecond) ms: \(value)")
            previous = value
        }
        let firstFrame = TimedProgress.progress(at: (1.0 / 120) / seconds, curve: .settle)
        #expect(firstFrame > 0.15, "the first 120 Hz frame covers \(firstFrame)")
        let spring = SpringParameters(response: 0.15, dampingFraction: 1)
        let springFirstFrame = 1 - (1 + spring.omega / 120) * exp(-spring.omega / 120)
        #expect(firstFrame > 3 * springFirstFrame, "a critically damped spring's first frame is \(springFirstFrame)")
        #expect(TimedProgress.progress(at: 1, curve: .settle) == 1)
    }

    /// The switches, in the gate's order: the master switch, the category, speed, then Reduce Motion and a live
    /// resize; `normal` is 1.5 times longer, as every other time constant.
    @Test func theCurveObeysEverySwitch() {
        #expect(policy().duration(curve: .settle) == MotionScale.settle)
        #expect(abs(policy(speed: .normal).duration(curve: .settle) - MotionScale.settle * 1.5) < 1e-12)
        #expect(policy(speed: .off).duration(curve: .settle) == 0)
        #expect(policy(enabled: false).duration(curve: .settle) == 0)
        #expect(policy(disabled: [.home]).duration(curve: .settle) == 0)
        #expect(policy(disabled: [.sidebar]).duration(curve: .settle) == MotionScale.settle)
        // Movement, not a fade: Reduce Motion makes it instant, with no crossfade standing in.
        #expect(policy(reduceMotion: true).duration(curve: .settle) == 0)
        #expect(policy(liveResize: true).duration(curve: .settle) == 0)
    }

    /// With motion off a run applies its end in the same turn and runs its completion; with it on, the end waits
    /// for the clock's frames.
    @Test(arguments: [0, 1, 2, 3])
    func motionOffAppliesInOneFrameAndRunsTheCompletion(_ switchOff: Int) {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var applied: [Double] = []
        var completed = 0
        let progress = TimedProgress { applied.append($0) }
        let run = {
            Motion.home.run(progress, curve: .settle, in: view, trace: "test.settle") { completed += 1 }
        }
        switch switchOff {
        case 0: with(enabled: false) { run() }
        case 1: with(disabled: [.home]) { run() }
        case 2: with(speed: .off) { run() }
        default: with(reduceMotion: true) { run() }
        }
        #expect(applied == [1])
        #expect(completed == 1)
        #expect(!progress.isRunning)

        // An animator() change on the curve applies at once too, and its completion runs now.
        let animated = Flag()
        with(enabled: false) {
            Motion.home.animate(curve: .settle, in: view, { view.animator().frame.size.height = 40 },
                                completion: { animated.value = true })
        }
        #expect(view.frame.height == 40)
        #expect(animated.value)
    }

    /// With motion on, the run steps on the settle curve and ends exactly at 1, then its completion runs.
    @Test func aRunStepsOnTheSettleCurve() {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var applied: [Double] = []
        var completed = false
        let progress = TimedProgress { applied.append($0) }
        progress.run(duration: MotionScale.settle, curve: .settle, in: view, trace: "test.settle") { completed = true }
        #expect(applied.isEmpty)
        #expect(progress.motionStep(0.05))
        #expect(abs((applied.last ?? 0) - TimedProgress.progress(at: 0.05 / MotionScale.settle, curve: .settle)) < 1e-9)
        #expect(progress.motionStep(1))
        #expect(applied.last == 1)
        #expect(!completed)
        #expect(!progress.motionStep(1.0 / 120))
        #expect(completed)
        progress.stop()
    }
}

/// A completion's mark, sendable to a `@Sendable` completion.
@MainActor private final class Flag {
    var value = false
}
