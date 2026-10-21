@testable import CmuxNextControl
import Foundation
import Testing

/// The CLI click's pointer path (`cmux browser … click`): the same model as
/// the browser REPL's human-mouse.js (plans/cmux-next/human-mouse-DESIGN.md).
struct HumanPointerPathTests {
    private func speeds(_ path: [HumanPointerPath.Sample], from: CGPoint) -> [Double] {
        var prev = HumanPointerPath.Sample(t: 0, x: from.x, y: from.y)
        return path.map { s in defer { prev = s }; return hypot(s.x - prev.x, s.y - prev.y) / max(s.t - prev.t, 0.001) }
    }

    @Test func timeFollowsFittsAndIsCapped() {
        let model = HumanPointerPath()
        #expect(model.duration(distance: 400, width: 24) > model.duration(distance: 100, width: 24))
        #expect(model.duration(distance: 200, width: 80) < model.duration(distance: 200, width: 10))
        #expect(model.duration(distance: 5_000, width: 1) == 350)
        #expect(HumanPointerPath(maxMoveMs: 200).duration(distance: 5_000, width: 1) == 200)
        #expect(model.duration(distance: 0, width: 24) == 0)
    }

    @Test(arguments: [1, 2, 3, 42, 99] as [UInt32])
    func pathEndsOnTheTargetAtDisplayRate(seed: UInt32) throws {
        let from = CGPoint(x: 20, y: 30), to = CGPoint(x: 640, y: 410)
        let path = HumanPointerPath().plan(from: from, to: to, width: 24, seed: seed)
        #expect(path.count >= 10)
        let last = try #require(path.last)
        #expect(last.x == 640 && last.y == 410)
        for (a, b) in zip(path, path.dropFirst()) {
            #expect(b.t - a.t > 10 && b.t - a.t < 24, "about one 60 Hz frame")
        }
        #expect(last.t <= 350)
        let s = speeds(path, from: from)
        let peak = try #require(s.max())
        #expect(try #require(s.last) < peak * 0.5, "slow arrival")
        #expect(s[0] < peak * 0.7, "slow start")
    }

    @Test func pathsCurveAndTheSameSeedRepeats() {
        let model = HumanPointerPath()
        let from = CGPoint(x: 0, y: 0), to = CGPoint(x: 800, y: 0)
        let curved = (1...20).filter { seed in
            let path = model.plan(from: from, to: to, width: 24, seed: UInt32(seed))
            let deviation = path.map { abs($0.y) }.max() ?? 0
            return deviation >= 2 && deviation <= 800 * 0.15 + 2
        }
        #expect(curved.count >= 15)
        #expect(model.plan(from: from, to: to, width: 24, seed: 7) == model.plan(from: from, to: to, width: 24, seed: 7))
    }

    @Test func instantMotionIsOneSample() {
        let path = HumanPointerPath(motion: .instant).plan(from: .zero, to: CGPoint(x: 500, y: 500), width: 24, seed: 1)
        #expect(path == [HumanPointerPath.Sample(t: 0, x: 500, y: 500)])
    }
}
