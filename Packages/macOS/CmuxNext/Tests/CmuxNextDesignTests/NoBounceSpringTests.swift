@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import QuartzCore
import Testing

/// No bounce in any motion (Lawrence 2026-11-10; plans/cmux-next/motion-first-principles-DESIGN.md,
/// principle 5: "Position never passes its target ... overshoot is 0 pixels"). Every spring the app
/// can make is stepped here, sample by sample: each Motion token at each speed, the fallback of a
/// token with no default, and the lowest damping a Debug Settings override may take. From rest, from
/// a new target under a moving value, and from a velocity a caller wrote (a release), no sample is
/// past the target by more than 1e-6 of the travel, and a value never moves away from its target.
@MainActor @Suite struct NoBounceSpringTests {
    /// The travel of every move here, in points.
    static let travel: CGFloat = 200
    /// 1e-6 of the travel.
    static let allowed: CGFloat = 200 * 1e-6
    static let rates: [Double] = [60, 120, 480]

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let spring: SpringParameters
        var testDescription: String { name }
    }

    /// Every spring configuration the app can produce.
    nonisolated static let cases: [Case] = {
        var out: [Case] = []
        for speed in MotionSpeed.allCases {
            let policy = MotionPolicy(speed: speed, reduceMotion: false)
            for token in MotionSpring.allCases {
                out.append(Case(name: "\(token.rawValue) at speed \(speed.rawValue)", spring: policy.spring(token)))
            }
        }
        out.append(Case(name: "the fallback of a token with no default", spring: MotionTunables.fallbackSpring))
        // Debug Settings: an override is clamped to the spring limits before a token reads it.
        let lowest = TunableKind.spring.clamp(.spring(SpringParameters(response: 0.2, dampingFraction: 0)))
        if case .spring(let spring)? = lowest {
            out.append(Case(name: "a Debug Settings override at the lowest damping", spring: spring))
        }
        return out
    }()

    /// What one run showed: how far the value went past its target, and how far it went back
    /// from where it started (away from the target).
    struct Run {
        var past: CGFloat = 0
        var away: CGFloat = 0
        var end: CGFloat = 0
    }

    /// Steps `value` for 3 s at `hz` and measures it against its target.
    static func run(_ start: SpringValue, _ spring: SpringParameters, hz: Double, settles: Bool = false) -> Run {
        var value = start
        let from = value.value, target = value.target
        let direction: CGFloat = target >= from ? 1 : -1
        var out = Run()
        for _ in 0..<Int(3 * hz) {
            if settles {
                _ = value.advance(1 / hz, parameters: spring, epsilon: 0.25)
            } else {
                value.step(1 / hz, parameters: spring)
            }
            out.past = max(out.past, (value.value - target) * direction)
            out.away = max(out.away, (from - value.value) * direction)
        }
        out.end = value.value
        return out
    }

    static func check(_ run: Run, _ what: String, _ item: Case) {
        #expect(run.past <= allowed,
                "\(item.name) (\(item.spring.response) / \(item.spring.dampingFraction)): \(what) passes its target by \(run.past) pt")
        #expect(run.away <= allowed,
                "\(item.name) (\(item.spring.response) / \(item.spring.dampingFraction)): \(what) moves \(run.away) pt away from its target")
    }

    /// SwiftUI (`Animation.spring(response:dampingFraction:)`) and Core Animation take the numbers
    /// as they are: under 1 passes the target.
    @Test(arguments: cases)
    func noSpringIsUnderDamped(_ item: Case) {
        #expect(item.spring.dampingFraction >= 1, "\(item.name) has damping \(item.spring.dampingFraction)")
        #expect(item.spring.response > 0)
    }

    @Test(arguments: cases)
    func aMoveFromRestNeverPassesItsTarget(_ item: Case) {
        for hz in Self.rates {
            for settles in [false, true] {
                var value = SpringValue(0)
                value.target = Self.travel
                let run = Self.run(value, item.spring, hz: hz, settles: settles)
                Self.check(run, "a \(Int(Self.travel)) pt move from rest at \(Int(hz)) Hz", item)
                #expect(abs(run.end - Self.travel) < 0.25, "\(item.name) is not at its target after 3 s (\(run.end))")
            }
        }
    }

    /// A new target while the value moves: nearer on the same side, the place the value is at, and
    /// behind it (the move is taken back).
    @Test(arguments: cases)
    func aNewTargetUnderAMovingValueIsNeverPassed(_ item: Case) {
        for hz in [60.0, 120.0] {
            for frames in [1, 2, 3, 5, 8, 12, 20] {
                var moving = SpringValue(0)
                moving.target = Self.travel
                for _ in 0..<frames { moving.step(1 / hz, parameters: item.spring) }
                for offset in [0.5, 5, 50, 0, -0.5, -5, -50] as [CGFloat] {
                    var value = moving
                    value.target = moving.value + offset
                    let run = Self.run(value, item.spring, hz: hz)
                    Self.check(run, "a retarget \(offset) pt from the value after \(frames) frames at \(Int(hz)) Hz", item)
                }
            }
        }
    }

    /// A velocity a caller wrote (a divider release, a fling, a dropped tab): toward the target it
    /// may not carry the value past it; away from the target it does not carry at all.
    @Test(arguments: cases)
    func aWrittenVelocityNeverCarriesAValuePastItsTarget(_ item: Case) {
        for distance in [1, 20, 200] as [CGFloat] {
            for velocity in [500, 5000, 50000, -500, -5000, -50000] as [CGFloat] {
                var value = SpringValue(0)
                value.target = distance
                value.velocity = velocity
                let run = Self.run(value, item.spring, hz: 120)
                Self.check(run, "\(distance) pt from its target at \(velocity) pt/s", item)
            }
        }
        // At its target with a velocity: it stays.
        var resting = SpringValue(40)
        resting.velocity = 3000
        let run = Self.run(resting, item.spring, hz: 120)
        Self.check(run, "at its target at 3000 pt/s", item)
    }

    /// The limit: a velocity toward the target carries up to omega x distance (it is not dropped).
    @Test(arguments: cases)
    func aVelocityTowardTheTargetStillCarries(_ item: Case) {
        var slow = SpringValue(0), fast = SpringValue(0)
        slow.target = Self.travel
        fast.target = Self.travel
        fast.velocity = 100_000
        slow.step(1.0 / 120, parameters: item.spring)
        fast.step(1.0 / 120, parameters: item.spring)
        #expect(fast.value > slow.value, "\(item.name): a release toward the target starts no faster than one from rest")
        #expect(fast.value <= Self.travel + Self.allowed)
    }

    /// A rect's far edge is x plus width, two springs: no edge passes its place, also when a
    /// caller wrote a velocity into one of them, or when they are not in step.
    @Test(arguments: cases)
    func noEdgeOfAFramePassesItsPlace(_ item: Case) {
        let omega = CGFloat(item.spring.omega)
        var fling = AnimatedFrame(CGRect(x: 0, y: 0, width: 100, height: 100))
        fling.setTarget(CGRect(x: 60, y: 40, width: 160, height: 120))
        fling.x.velocity = 5000
        fling.width.velocity = 5000
        fling.y.velocity = -5000
        fling.height.velocity = 9000
        // The far edge rests on its place and the two springs under it are not in step.
        var split = AnimatedFrame(CGRect(x: 40, y: 0, width: 110, height: 100))
        split.setTarget(CGRect(x: 50, y: 0, width: 100, height: 100))
        split.x.velocity = omega * 10
        // `advance` rests each spring by itself, once it is within a quarter point and slow: two
        // springs under one edge may rest a frame apart, so a path that rests by itself may be a rest
        // snap (a quarter point at most) off, and the frame whose far edge must not move at all steps
        // unsettled only (as the panes of a split do, `advanceUnsettled`).
        for (name, start, modes) in [("a flung frame", fling, [false, true]), ("a frame whose far edge rests", split, [true])] {
            for unsettled in modes {
                var frame = start
                let target = frame.targetRect
                let targets = [target.minX, target.maxX, target.minY, target.maxY]
                let from = [frame.rect.minX, frame.rect.maxX, frame.rect.minY, frame.rect.maxY]
                var past: CGFloat = 0, away: CGFloat = 0
                for _ in 0..<360 {
                    if unsettled {
                        _ = frame.advanceUnsettled(1.0 / 120, parameters: item.spring)
                    } else {
                        _ = frame.advance(1.0 / 120, parameters: item.spring)
                    }
                    let now = [frame.rect.minX, frame.rect.maxX, frame.rect.minY, frame.rect.maxY]
                    for edge in 0..<4 {
                        let direction: CGFloat = targets[edge] >= from[edge] ? 1 : -1
                        past = max(past, (now[edge] - targets[edge]) * direction)
                        away = max(away, (from[edge] - now[edge]) * direction)
                    }
                }
                let allowed = unsettled ? Self.allowed : 0.25
                #expect(past <= allowed, "\(item.name): an edge of \(name) passes its place by \(past) pt")
                #expect(away <= allowed, "\(item.name): an edge of \(name) moves \(away) pt away from its place")
            }
        }
    }

    /// The spring Core Animation runs for a token (`MotionGate.springAnimation`: mass 1, the
    /// token's stiffness and damping), sampled with the render server's equation.
    @Test(arguments: MotionSpring.allCases)
    func theRenderServerSpringNeverPassesItsEnd(_ token: MotionSpring) {
        let animation = Motion.tabs.springAnimation(token, "position.x", from: 0, to: Self.travel)
        var highest: CGFloat = 0
        var time: CFTimeInterval = 0
        while time < animation.duration + 0.5 {
            highest = max(highest, MotionPath.springProgress(animation, at: time))
            time += 1.0 / 480
        }
        #expect(highest <= 1 + 1e-6, "\(token.rawValue): the Core Animation spring reaches \(highest) of its travel")
        #expect(highest > 0.99, "\(token.rawValue): the Core Animation spring does not arrive (\(highest))")
    }
}
