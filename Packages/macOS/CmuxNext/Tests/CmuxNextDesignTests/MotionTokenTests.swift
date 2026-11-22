import AppKit
import Testing
@testable import CmuxNextDesign

/// The motion rules from plans/cmux-next/motion.md, checked on the pure
/// policy so they hold for every module that reads `Motion`.
@Suite struct MotionTokenTests {
    let fast = MotionPolicy(speed: .fast, reduceMotion: false)

    @Test func structuralChangesEndVisiblyIn150To250Milliseconds() {
        // The length a viewer reads: the last visible pixel of a 200 pt move.
        for token: MotionSpring in [.move, .appear, .settle, .scroll, .screen] {
            let seconds = fast.spring(token).perceivedDuration
            #expect(seconds >= 0.15 && seconds <= 0.25, "\(token) reads as \(seconds) s")
        }
        // Disappearing and panels are faster still, but never a cut.
        for token: MotionSpring in [.disappear, .panel] {
            let seconds = fast.spring(token).perceivedDuration
            #expect(seconds >= 0.1 && seconds < 0.15, "\(token) reads as \(seconds) s")
        }
    }

    @Test func disappearingIsFasterThanAppearingAndAppearingFasterThanMoving() {
        #expect(fast.spring(.disappear).perceivedDuration < fast.spring(.appear).perceivedDuration)
        #expect(fast.spring(.appear).perceivedDuration < fast.spring(.move).perceivedDuration)
        #expect(fast.duration(MotionFade.fadeOut) < fast.duration(MotionFade.fadeIn))
    }

    @Test func microFeedbackIsATenthOfASecondOrLess() {
        for token: MotionFade in [.hover, .focus, .fadeOut, .crossfade] {
            #expect(fast.duration(token) <= 0.1, "\(token)")
        }
        #expect(fast.spring(.track).perceivedDuration <= 0.12)
    }

    @Test func springsAreCriticallyOrSlightlyUnderDamped() {
        for token in MotionSpring.allCases {
            let damping = token.base.dampingFraction
            #expect(damping >= 0.8 && damping <= 1, "\(token) damping \(damping)")
        }
    }

    @Test func normalIsOneAndAHalfTimesFast() {
        let normal = MotionPolicy(speed: .normal, reduceMotion: false)
        for token in MotionSpring.allCases {
            #expect(abs(normal.spring(token).response - token.base.response * 1.5) < 1e-9)
            #expect(normal.spring(token).dampingFraction == token.base.dampingFraction)
        }
        for token in MotionFade.allCases {
            #expect(abs(normal.duration(token) - token.baseDuration * 1.5) < 1e-9)
        }
        #expect(normal.animatesMovement && normal.animatesFades && normal.animatesLoops)
    }

    @Test func offAppliesEveryChangeInOneFrame() {
        let off = MotionPolicy(speed: .off, reduceMotion: false)
        #expect(!off.animatesMovement)
        #expect(!off.animatesFades)
        #expect(!off.animatesLoops)
        for token in MotionFade.allCases { #expect(off.duration(token) == 0) }
        for token in MotionSpring.allCases { #expect(off.duration(token) == 0) }
        for loop in MotionLoop.allCases { #expect(off.period(loop) == nil) }
    }

    @Test func reduceMotionReplacesMovementWithAShortCrossfade() {
        for speed in [MotionSpeed.fast, .normal] {
            let reduced = MotionPolicy(speed: speed, reduceMotion: true)
            #expect(!reduced.animatesMovement)
            #expect(reduced.animatesFades)
            #expect(!reduced.animatesLoops)
            for token in MotionSpring.allCases { #expect(reduced.duration(token) == 0) }
            for token in MotionFade.allCases {
                #expect(reduced.duration(token) > 0)
                #expect(reduced.duration(token) <= MotionFade.crossfade.baseDuration)
            }
        }
        // Off wins over Reduce Motion: no crossfade either.
        #expect(MotionPolicy(speed: .off, reduceMotion: true).duration(MotionFade.fadeIn) == 0)
    }

    @Test func springConstantsMatchCoreAnimation() {
        let spring = SpringParameters(response: 0.2, dampingFraction: 1)
        let omega = 2 * Double.pi / 0.2
        #expect(abs(spring.stiffness - omega * omega) < 1e-9)
        #expect(abs(spring.damping - 2 * omega) < 1e-9)
        // A critically damped step is within 1% after about 1.056 responses
        // ((1 + wt) e^-wt = 0.01 at wt = 6.64).
        #expect(abs(spring.settlingTime(within: 0.01) - 1.056 * 0.2) < 0.002)
    }

    @Test func perceivedDurationMatchesASimulatedStep() {
        for token in MotionSpring.allCases {
            let parameters = token.base
            var value = SpringValue(0)
            value.target = 1
            var elapsed = 0.0
            var lastOutside = 0.0
            while elapsed < 1 {
                value.step(1.0 / 480.0, parameters: parameters)
                elapsed += 1.0 / 480.0
                if abs(1 - value.value) > 0.01 { lastOutside = elapsed }
            }
            // The envelope bound never undershoots the real settle time.
            #expect(lastOutside <= parameters.settlingTime(within: 0.01) + 0.005, "\(token)")
        }
    }
}
