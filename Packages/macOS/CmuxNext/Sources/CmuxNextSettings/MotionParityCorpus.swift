public import CmuxNextDesignTokens
import CoreGraphics

/// The motion parity corpus of this port (`debug.motion {action:
/// "trajectory"}`): every chrome spring token resolved under bounce none
/// and subtle at speed fast, and the frame path of a 200 pt move (and a
/// retarget to 50 pt after 5 frames) at 60 and 120 Hz until the spring
/// rests. cmux-motion's `motion_trajectories` example prints the same
/// document; scripts/cmux-next/motion-parity.py compares them.
/// `debug.motion` (CmuxNextApp) serves it; it lives here, beside the
/// motion settings, to keep the App target small.
public struct MotionParityCorpus {
    private let tokens = MotionSpring.allCases

    public init() {}

    public var document: JSONValue {
        var tokenRows: [JSONValue] = []
        var paths: [JSONValue] = []
        for bounce in [MotionBounce.none, .subtle] {
            let policy = MotionPolicy(speed: .fast, reduceMotion: false, bounce: bounce)
            for token in tokens {
                let spring = policy.spring(token)
                tokenRows.append([
                    "token": .string(token.rawValue), "bounce": .string(bounce.rawValue),
                    "response": .number(spring.response), "damping_fraction": .number(spring.dampingFraction),
                    "visible_end": .number(spring.perceivedDuration),
                ])
                for hz in [60.0, 120.0] {
                    for (name, retarget) in [("move", nil), ("retarget", (5, CGFloat(50)))] as [(String, (Int, CGFloat)?)] {
                        paths.append([
                            "token": .string(token.rawValue), "bounce": .string(bounce.rawValue), "hz": .number(hz),
                            "case": .string(name), "values": .array(path(spring, hz: hz, retarget: retarget).map { .number(Double($0)) }),
                        ])
                    }
                }
            }
        }
        return ["port": .string("swift"), "tokens": .array(tokenRows), "paths": .array(paths)]
    }

    private func path(_ spring: SpringParameters, hz: Double, retarget: (Int, CGFloat)?) -> [CGFloat] {
        var value = SpringValue(0)
        value.target = 200
        var out: [CGFloat] = []
        for frame in 0..<Int(3 * hz) {
            if let retarget, retarget.0 == frame { value.target = retarget.1 }
            let moving = value.advance(1 / hz, parameters: spring, epsilon: 0.25)
            out.append(value.value)
            if !moving { break }
        }
        return out
    }
}
