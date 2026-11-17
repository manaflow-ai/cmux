import Foundation
import Testing
@testable import CmuxHomeRender

@Suite struct MotionTokenTests {
    static let moves: [SpringElement] = [
        HomeMotion.send, HomeMotion.delivered, HomeMotion.read, HomeMotion.typing, HomeMotion.receive,
        HomeMotion.bubbleRight, HomeMotion.bubbleWidth, HomeMotion.bubbleCenterY, HomeMotion.bubbleOpacity, HomeMotion.fieldTop,
    ]
    static let pulses: [SpringElement] = [HomeMotion.bubbleScale, HomeMotion.fieldOpacity]
    static let effects: [SpringElement] = [
        HomeMotion.typingPop, HomeMotion.typingFade, HomeMotion.typingOut, HomeMotion.receivedFade, HomeMotion.receiptIn,
        HomeMotion.receiptOldOut, HomeMotion.receiptNewIn, HomeMotion.rowFade, HomeMotion.textUnblur, HomeMotion.fieldGrow,
    ]

    /// A move starts at `from` and rests at `to` (within 0.5% of the distance).
    @Test(arguments: moves)
    func moveRunsFromStartToEnd(element: SpringElement) {
        let distance = abs(element.to - element.from)
        #expect(abs(element.value(-0.05, from: element.from, to: element.to) - element.from) < 0.005 * distance)
        #expect(abs(element.value(element.settleTime, from: element.from, to: element.to) - element.to) < 0.005 * distance)
        #expect(element.settleTime > 0.1 && element.settleTime < 1.5, "\(element.name) settles in \(element.settleTime) s")
    }

    /// A pulse leaves its base and returns to it.
    @Test(arguments: pulses)
    func pulseReturnsToBase(element: SpringElement) {
        #expect(element.isPulse)
        let peak = stride(from: 0.0, through: element.settleTime, by: 1.0 / 240).map { abs(element.value($0, from: 1, to: 1) - 1) }.max() ?? 0
        #expect(peak > 0.05)
        #expect(abs(element.value(element.settleTime + 0.01, from: 1, to: 1) - 1) < 0.01)
    }

    /// Effects are structural and settle within 0.8 s (their visible end is
    /// earlier; motion.md rule 5).
    @Test(arguments: effects)
    func effectsAreShort(element: SpringElement) {
        #expect(element.settleTime < 0.8, "\(element.name) settles in \(element.settleTime) s")
        #expect(abs(element.value(element.settleTime, from: 0, to: 1) - 1) < 0.01)
    }

    /// `normal` speed multiplies every time constant by 1.5 (motion.md rule 8).
    @Test func normalSpeedScalesTimeConstants() {
        let fast = HomeMotion.receive
        let normal = fast.scaled(HomeAnimationSpeed.normal.factor)
        #expect(abs(normal.settleTime / fast.settleTime - 1.5) < 0.05)
        #expect(abs(normal.value(0.3, from: 0, to: 1) - fast.value(0.2, from: 0, to: 1)) < 1e-9)
    }

    /// Reduce Motion: no movement, a cross-fade of at most 0.1 s; `off` wins
    /// over Reduce Motion (motion.md rules 7 and 8).
    @Test func motionPolicyMatchesMotionRules() {
        #expect(MotionPolicy().moves)
        #expect(!MotionPolicy().crossFades)
        let reduced = MotionPolicy(reduceMotion: true, speed: .fast)
        #expect(!reduced.moves && reduced.crossFades && !reduced.loops && reduced.caretBlinks)
        let off = MotionPolicy(reduceMotion: true, speed: .off)
        #expect(!off.moves && !off.crossFades && !off.loops && !off.caretBlinks)
        #expect(HomeMotion.crossFade <= 0.1)
    }

    /// The closed form agrees with a numeric integration of the same spring.
    @Test func closedFormMatchesIntegration() {
        let spring = Spring(duration: 0.3008, bounce: 0.0975)
        var x = 0.0, v = 0.0
        let dt = 1e-5
        var t = 0.0
        while t < 0.25 {
            let a = -spring.stiffness * (x - 1) - spring.damping * v
            v += a * dt
            x += v * dt
            t += dt
        }
        #expect(abs(spring.progress(t) - x) < 1e-3)
    }
}
