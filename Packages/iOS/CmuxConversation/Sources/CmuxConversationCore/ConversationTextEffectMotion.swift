import Foundation

/// Per-glyph motion of the animated text effects, shared by iOS and macOS.
/// Each effect plays once per `cycle`, then rests; bubbles loop it while
/// visible. Times are seconds, distances are in units of the font size so
/// the same motion reads the same in a 17 pt iOS bubble and a 13 pt Mac one.
public enum ConversationTextEffectMotion {
    public struct Pose: Sendable, Hashable {
        public var dx: Double = 0
        public var dy: Double = 0
        /// Radians, clockwise in top-left-origin space.
        public var rotation: Double = 0
        public var scale: Double = 1
        public var opacity: Double = 1

        public static let rest = Pose()
    }

    /// One play plus the pause before the next.
    public static let cycle: Double = 3.0

    /// Big and Small also change the type size; the others keep it.
    public static func fontScale(_ effect: ConversationTextEffect) -> Double {
        switch effect {
        case .big: return 1.6
        case .small: return 0.7
        default: return 1
        }
    }

    /// Delay before unit `index` of `count` starts, so motion travels across the run.
    public static func delay(_ effect: ConversationTextEffect, index: Int, count: Int) -> Double {
        let count = max(1, count)
        // Long runs compress the stagger so the wave still fits one cycle.
        let spread = { (perUnit: Double, cap: Double) in min(perUnit, cap / Double(count)) * Double(index) }
        switch effect {
        case .ripple: return spread(0.045, 1.1)
        case .nod: return spread(0.03, 0.6)
        case .big, .small: return spread(0.02, 0.4)
        case .bloom:
            let center = Double(count - 1) / 2
            return min(0.035, 0.7 / Double(count)) * abs(Double(index) - center)
        case .shake, .explode, .jitter: return 0
        }
    }

    /// Duration of one unit's motion (excluding its delay).
    public static func duration(_ effect: ConversationTextEffect) -> Double {
        switch effect {
        case .shake: return 0.7
        case .nod: return 0.9
        case .explode: return 1.1
        case .ripple: return 0.5
        case .bloom: return 0.8
        case .jitter: return 1.2
        case .big, .small: return 0.55
        }
    }

    /// Pose of unit `index` of `count`, `t` seconds after the cycle began.
    /// `seed` varies explode directions and jitter paths per message.
    public static func pose(
        _ effect: ConversationTextEffect,
        index: Int,
        count: Int,
        time t: Double,
        seed: UInt64 = 0
    ) -> Pose {
        let local = t - delay(effect, index: index, count: count)
        let d = duration(effect)
        guard local >= 0, local <= d else { return .rest }
        let p = local / d
        var pose = Pose()
        switch effect {
        case .shake:
            // Fast side-to-side shudder that dies out.
            pose.dx = 0.16 * sin(2 * .pi * 6 * local) * (1 - p)
        case .nod:
            // Two nods: dip and tilt forward, then recover.
            let wave = sin(2 * .pi * 2 * p) * (1 - p)
            pose.dy = 0.14 * wave
            pose.rotation = 0.10 * wave
        case .explode:
            let angle = unitRandom(seed, index, 1) * 2 * .pi
            let distance = 0.9 + 0.8 * unitRandom(seed, index, 2)
            let spin = (unitRandom(seed, index, 3) - 0.5) * 1.6
            // Burst out (ease-out) for the first 35%, drift back (ease-in-out).
            let out = p < 0.35 ? easeOut(p / 0.35) : 1 - easeInOut((p - 0.35) / 0.65)
            pose.dx = cos(angle) * distance * out
            pose.dy = sin(angle) * distance * out
            pose.rotation = spin * out
            pose.scale = 1 + 0.35 * out
            pose.opacity = 1 - 0.35 * out
        case .ripple:
            // A single swell passing through: rise, grow, settle.
            let bump = sin(.pi * p)
            pose.dy = -0.32 * bump
            pose.scale = 1 + 0.22 * bump
        case .bloom:
            // Petals open from the middle: grow from small and fade in, slight overshoot.
            let s = spring(p)
            pose.scale = 0.25 + 0.75 * s
            pose.opacity = min(1, p / 0.35)
        case .jitter:
            // Nervous random steps at ~24 Hz, fading out at the end.
            let step = Int(local * 24)
            let fade = p > 0.8 ? (1 - p) / 0.2 : 1
            pose.dx = (unitRandom(seed, index, 10 + 2 * step) - 0.5) * 0.14 * fade
            pose.dy = (unitRandom(seed, index, 11 + 2 * step) - 0.5) * 0.14 * fade
            pose.rotation = (unitRandom(seed, index, 1000 + step) - 0.5) * 0.12 * fade
        case .big:
            pose.scale = 0.45 + 0.55 * spring(p)
        case .small:
            pose.scale = 1.6 - 0.6 * spring(p)
        }
        return pose
    }

    /// Deterministic value in [0, 1) for (seed, unit, salt).
    static func unitRandom(_ seed: UInt64, _ index: Int, _ salt: Int) -> Double {
        var x = seed &+ UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(truncatingIfNeeded: salt) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// Underdamped settle from 0 to 1 (about 12% overshoot), exactly 1 at x = 1.
    static func spring(_ x: Double) -> Double {
        guard x < 1 else { return 1 }
        return 1 - exp(-6 * x) * cos(2.4 * .pi * x) * (1 - x)
    }

    /// Stable per-message seed (FNV-1a of the row identity).
    public static func seed(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
