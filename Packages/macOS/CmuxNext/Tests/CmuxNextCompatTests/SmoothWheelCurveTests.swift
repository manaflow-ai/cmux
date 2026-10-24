import Testing
import CmuxNextCompat

/// A wheel notch is paid out over several frames, not in one jump (user 2026-10-24:
/// "make webviews mouse scroll smoothly like Chrome").
struct SmoothWheelCurveTests {
    private func frames(_ curve: inout SmoothWheelCurve, fps: Double = 60, limit: Int = 120) -> [Int] {
        var steps: [Int] = []
        while !curve.isIdle, steps.count < limit { steps.append(curve.advance(seconds: 1 / fps)) }
        return steps
    }

    @Test func oneNotchTakesSeveralFramesAndKeepsItsDistance() {
        var curve = SmoothWheelCurve()
        curve.add(distance: -120)
        let steps = frames(&curve)
        #expect(steps.count >= 6, "a notch spread over \(steps.count) frames: \(steps)")
        #expect(steps.count <= 20)
        #expect(steps.reduce(0, +) == -120)
        #expect(steps.allSatisfy { $0 <= 0 })
        // Ease-out: the first frame is the largest, the last the smallest.
        #expect(abs(steps.first!) > abs(steps.last!))
        #expect(abs(steps.first!) < 120)
    }

    @Test func notchesAddUp() {
        var curve = SmoothWheelCurve()
        curve.add(distance: 120)
        let first = curve.advance(seconds: 1 / 60)
        curve.add(distance: 120)
        let rest = frames(&curve)
        #expect(first + rest.reduce(0, +) == 240)
    }

    @Test func rateFollowsTimeNotFrameCount() {
        var slow = SmoothWheelCurve(), fast = SmoothWheelCurve()
        slow.add(distance: 100); fast.add(distance: 100)
        let at30 = (0..<3).reduce(0) { total, _ in total + slow.advance(seconds: 1 / 30) }
        let at120 = (0..<12).reduce(0) { total, _ in total + fast.advance(seconds: 1 / 120) }
        #expect(abs(at30 - at120) <= 3, "after 100 ms: \(at30) px at 30 fps, \(at120) px at 120 fps")
    }

    @Test func finishPaysTheRest() {
        var curve = SmoothWheelCurve()
        curve.add(distance: 80)
        let first = curve.advance(seconds: 1 / 60)
        #expect(first + curve.finish() == 80)
        #expect(curve.isIdle)
    }
}
