@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import Testing

/// No motion takes longer than 300 ms to end visibly, at any animation speed, and the exit of a pair ends sooner
/// than its enter.
///
/// The time of a motion is its visible end: for a spring the last moment that it is more than 0.5% of its travel
/// from its target (`SpringParameters.perceivedDuration`), for a fade or a tween its duration. The speed `normal`
/// makes each time 1.5 times that of `fast`; a time that would then pass 300 ms is cut to 300 ms, and a shorter
/// one is not changed (`theCapChangesNoTimeUnderIt`). The default speed, `fast`, has no time over the cap.
///
/// Not motions that a person waits for, so not under the cap, and each is named here:
/// - the four ambient fades of `ambientLimits`, each with its own limit, so that none gets slower unseen;
/// - the loops (`MotionLoop`): each shows a state for as long as the state lasts, and the speed does not scale
///   one (`theSpeedDoesNotScaleALoop`);
/// - the blinks of an attention ring and a title's marquee: a signal with a count and a reading speed.
///
/// No window, no clock, no sleep: each case asks a `MotionPolicy` value. A case stops with SETUP when a Debug
/// Settings override of its token is active on the host.
@MainActor @Suite struct MotionCapTests {
    /// The longest a motion may take to end visibly, in seconds.
    static let cap: TimeInterval = 0.3
    /// The tab tweens at `normal` are 0.2 x 1.5: at the cap, but for the last bit of the product.
    static let tolerance: TimeInterval = 1e-9
    /// The speeds that animate.
    static let speeds: [MotionSpeed] = [.fast, .normal]

    /// The ambient fades, not transitions (`MotionScaleTests.ambientFades` says why for each): the longest each
    /// may take at any speed, 1.5 times its time at `fast`.
    static let ambientLimits: [MotionFade: TimeInterval] = [
        .focusFlash: 0.75,
        .wallpaper: 0.9,
        .hibernateRing: 1.5,
        .highlight: 1.8,
    ]

    static func policy(_ speed: MotionSpeed) -> MotionPolicy {
        MotionPolicy(speed: speed, reduceMotion: false, enabledKinds: Set(MotionKind.allCases))
    }

    static func ms(_ seconds: TimeInterval) -> String { "\((seconds * 10_000).rounded() / 10) ms" }

    // MARK: The cap

    @Test(arguments: MotionSpring.allCases)
    func everySpringEndsVisiblyByTheCap(_ spring: MotionSpring) throws {
        let code = try #require(MotionTunables.springDefaults[spring]?.0, "\(spring) has no default")
        try #require(spring.base == code, "SETUP: a Debug Settings override of the \(spring) spring is active on this host")
        for speed in Self.speeds {
            let end = Self.policy(speed).duration(spring)
            #expect(end > 0, "the \(spring) spring does not animate at speed \(speed.rawValue)")
            #expect(end <= Self.cap + Self.tolerance, "the \(spring) spring at speed \(speed.rawValue) ends visibly at \(Self.ms(end)), past the 300 ms cap")
        }
    }

    @Test(arguments: MotionFade.allCases)
    func everyFadeEndsByTheCap(_ fade: MotionFade) throws {
        let code = try #require(MotionTunables.fadeDefaults[fade]?.0, "\(fade) has no default")
        try #require(fade.baseDuration == code, "SETUP: a Debug Settings override of the \(fade) fade is active on this host")
        for speed in Self.speeds {
            let seconds = Self.policy(speed).duration(fade)
            if let limit = Self.ambientLimits[fade] {
                #expect(seconds > Self.cap, "the \(fade) fade is listed as ambient but takes \(Self.ms(seconds)) at speed \(speed.rawValue), under the cap: take it off the list")
                #expect(seconds <= limit + Self.tolerance, "the ambient \(fade) fade at speed \(speed.rawValue) takes \(Self.ms(seconds)), past its limit of \(Self.ms(limit))")
            } else {
                #expect(seconds <= Self.cap + Self.tolerance, "the \(fade) fade at speed \(speed.rawValue) takes \(Self.ms(seconds)), past the 300 ms cap")
            }
        }
    }

    @Test(arguments: MotionTween.allCases)
    func everyTweenEndsByTheCap(_ tween: MotionTween) throws {
        for speed in Self.speeds {
            let seconds = Self.policy(speed).duration(tween)
            try #require(seconds > 0, "SETUP: the \(tween) tween does not animate at speed \(speed.rawValue)")
            #expect(seconds <= Self.cap + Self.tolerance, "the \(tween) tween at speed \(speed.rawValue) takes \(Self.ms(seconds)), past the 300 ms cap")
        }
    }

    /// The two timed motions that are no token take the policy's scale (`MotionPolicy.scaled`), so the same cap.
    @Test func aTimedMotionThatIsNoTokenEndsByTheCap() {
        let longest: [(name: String, seconds: TimeInterval)] = [
            ("the agent cursor's longest glide", MotionTunables.agentCursorGlideMax.defaultValue),
            ("the attention ring's arrival swell", Motion.steadyPulseDuration),
        ]
        for (name, base) in longest {
            for speed in Self.speeds {
                let seconds = Self.policy(speed).scaled(base)
                #expect(seconds > 0, "\(name) does not animate at speed \(speed.rawValue)")
                #expect(seconds <= Self.cap + Self.tolerance, "\(name) at speed \(speed.rawValue) takes \(Self.ms(seconds)), past the 300 ms cap")
            }
        }
    }

    /// The cap cuts only a time that would pass it: at `fast` each token has its own time, and at `normal` a
    /// time that 1.5 times does not take past the cap is 1.5 times its time at `fast`.
    @Test func theCapChangesNoTimeUnderIt() throws {
        let fast = Self.policy(.fast), normal = Self.policy(.normal)
        let scale = MotionSpeed.normal.timeScale
        for spring in MotionSpring.allCases {
            let code = try #require(MotionTunables.springDefaults[spring]?.0, "\(spring) has no default")
            try #require(spring.base == code, "SETUP: a Debug Settings override of the \(spring) spring is active on this host")
            #expect(fast.spring(spring) == code, "the \(spring) spring at speed fast is not its token")
            let longer = code.scaled(by: scale)
            if longer.perceivedDuration <= Self.cap {
                #expect(normal.spring(spring) == longer, "the \(spring) spring at speed normal ends under the cap and is not \(scale) times its token")
            }
        }
        for fade in MotionFade.allCases {
            let code = try #require(MotionTunables.fadeDefaults[fade]?.0, "\(fade) has no default")
            try #require(fade.baseDuration == code, "SETUP: a Debug Settings override of the \(fade) fade is active on this host")
            #expect(fast.duration(fade) == code, "the \(fade) fade at speed fast is not its token")
            if code * scale <= Self.cap || Self.ambientLimits[fade] != nil {
                #expect(normal.duration(fade) == code * scale, "the \(fade) fade at speed normal is not \(scale) times its token")
            }
        }
        #expect(fast.scaled(0.1) == 0.1 && normal.scaled(0.1) == 0.1 * scale, "a timed motion of 100 ms is not its time times the speed's scale")
    }

    // MARK: What the cap does not cut

    @Test func theAmbientFadesAreTheOnesOfTheScale() {
        #expect(Set(Self.ambientLimits.keys) == Set(MotionScaleTests.ambientFades.keys), "the two lists of ambient fades differ")
    }

    @Test(arguments: MotionLoop.allCases)
    func theSpeedDoesNotScaleALoop(_ loop: MotionLoop) {
        let fast = Self.policy(.fast).period(loop), normal = Self.policy(.normal).period(loop)
        #expect(fast != nil, "the \(loop) loop does not run at speed fast")
        #expect(normal == fast, "the \(loop) loop has another period at speed normal")
    }

    // MARK: Pairs

    @Test(arguments: MotionPair.all.map(\.name))
    func anExitEndsSoonerThanItsEnter(_ name: String) throws {
        let pair = try #require(MotionPair.all.first { $0.name == name })
        for speed in Self.speeds {
            let policy = Self.policy(speed)
            let enter = policy.seconds(pair.enter), exit = policy.seconds(pair.exit)
            try #require(enter > 0 && exit > 0, "SETUP: a side of \(name) does not animate at speed \(speed.rawValue)")
            if let reason = pair.equalBecause {
                #expect(abs(exit - enter) <= Self.tolerance,
                        "\(name) is listed as equal (\(reason)) but at speed \(speed.rawValue) the exit takes \(Self.ms(exit)) and the enter \(Self.ms(enter)): take the reason off")
            } else {
                #expect(exit < enter - Self.tolerance,
                        "\(name) at speed \(speed.rawValue): the exit takes \(Self.ms(exit)), not less than the enter's \(Self.ms(enter))")
            }
        }
    }

    @Test func onlyTheTabPairIsEqual() {
        #expect(MotionPair.all.filter { $0.equalBecause != nil } == [MotionPair.tab])
        #expect(Set(MotionPair.all.map(\.name)).count == MotionPair.all.count, "two pairs have one name")
    }
}
