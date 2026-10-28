import CmuxNextSettings
import CoreGraphics
import Foundation

/// A person's pointer path for an agent click (plans/cmux-next/human-mouse-DESIGN.md):
/// Fitts's law time capped at `maxMoveMs`, minimum-jerk speed, a slightly
/// curved path, a correction on long moves, 60 Hz samples in whole CSS px.
/// The same model as the browser REPL's human-mouse.js, which the CLI click
/// (`browser.page.click`) cannot load (it runs in the app, not the host).
struct HumanPointerPath: Sendable {
    /// One pointer position `t` ms after the move starts.
    struct Sample: Sendable, Equatable {
        var t: Double
        var x: Double
        var y: Double
    }

    var motion: AgentMouseSetting.Motion = .human
    var maxMoveMs: Double = 350
    var minMoveMs: Double = 60
    var fittsA: Double = 50
    var fittsB: Double = 90
    var hz: Double = 60
    var curvature: Double = 0.08
    var correctionMinPx: Double = 120
    /// [min, max] ms of the rest before the press and of the press.
    var dwellMs: ClosedRange<Double> = 40...110
    var holdMs: ClosedRange<Double> = 50...110

    init(motion: AgentMouseSetting.Motion = .human, maxMoveMs: Double = 350) {
        self.motion = motion
        self.maxMoveMs = maxMoveMs
        self.minMoveMs = min(minMoveMs, maxMoveMs)
    }

    init(_ setting: AgentMouseSetting.Value) {
        self.init(motion: setting.motion, maxMoveMs: setting.maxMoveMs)
    }

    /// Fitts's law move time in ms for `distance` to a target `width` wide.
    func duration(distance: Double, width: Double) -> Double {
        guard distance >= 0.5 else { return 0 }
        let t = fittsA + fittsB * log2(distance / max(width, 1) + 1)
        return min(maxMoveMs, max(minMoveMs, t))
    }

    /// The samples from `from` to `to`; the last one is exactly `to`.
    func plan(from: CGPoint, to: CGPoint, width: Double, seed: UInt32) -> [Sample] {
        let d = hypot(to.x - from.x, to.y - from.y)
        let total = motion == .instant ? 0 : duration(distance: d, width: width)
        guard total > 0 else { return [Sample(t: 0, x: to.x, y: to.y)] }
        var rand = SeededRandom(seed: seed)
        let n = max(2, Int(exactly: min(10_000, (total / (1000 / hz)).rounded())) ?? 2)
        let side: Double = rand.next() < 0.5 ? -1 : 1
        let bend = side * min(0.12, curvature * (0.25 + 0.75 * rand.next()))
        let dir = CGPoint(x: (to.x - from.x) / d, y: (to.y - from.y) / d)
        var primary = SubMovement(from: from, to: to, bend: bend)
        var correction: SubMovement?
        var split = 1.0
        if d >= correctionMinPx {
            let reach = rand.next() < 0.6 ? 0.94 + 0.03 * rand.next() : 1.02 + 0.02 * rand.next()
            let lateral = (rand.next() * 2 - 1) * 0.015 * d
            let end = CGPoint(x: from.x + dir.x * d * reach - dir.y * lateral, y: from.y + dir.y * d * reach + dir.x * lateral)
            primary = SubMovement(from: from, to: end, bend: bend)
            correction = SubMovement(from: end, to: to, bend: 0)
            split = 0.78 + 0.07 * rand.next()
        }
        var out: [Sample] = []
        for i in 1...n {
            let u = Double(i) / Double(n)
            if i == n { out.append(Sample(t: total, x: to.x, y: to.y)); break }
            let p: CGPoint
            if let correction, u > split {
                p = correction.at((u - split) / (1 - split))
            } else {
                p = primary.at(u / split)
            }
            out.append(Sample(t: u * total, x: p.x.rounded(), y: p.y.rounded()))
        }
        return out
    }

    /// A rest or press length in `range`, peaked in the middle.
    func pause(_ range: ClosedRange<Double>, seed: UInt32) -> Double {
        var rand = SeededRandom(seed: seed)
        return range.lowerBound + (range.upperBound - range.lowerBound) * (rand.next() + rand.next()) / 2
    }
}

/// One curved minimum-jerk sub-movement (a cubic Bézier, control points
/// `bend`·length to one side).
private struct SubMovement {
    let p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint

    init(from a: CGPoint, to b: CGPoint, bend: Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let nx = -dy / len, ny = dx / len, h = bend * len
        p0 = a
        p1 = b
        c1 = CGPoint(x: a.x + dx * 0.3 + nx * h, y: a.y + dy * 0.3 + ny * h)
        c2 = CGPoint(x: a.x + dx * 0.7 + nx * h, y: a.y + dy * 0.7 + ny * h)
    }

    func at(_ u: Double) -> CGPoint {
        let s = u * u * u * (10 - 15 * u + 6 * u * u)
        let m = 1 - s
        let a = m * m * m, b = 3 * m * m * s, c = 3 * m * s * s, d = s * s * s
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x, y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }
}

/// mulberry32, as human-mouse.js: a seed gives one exact path.
private struct SeededRandom {
    var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Double {
        state = state &+ 0x6d2b79f5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}
