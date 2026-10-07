import CmuxTerminalRenderCore
import Testing

@Suite struct TerminalScrollMomentumTests {
    @Test func decaysToAStop() {
        var momentum = TerminalScrollMomentum(velocity: 2000)
        var total = 0.0
        var steps = 0
        while !momentum.isFinished, steps < 10_000 {
            total += momentum.step(1.0 / 120)
            steps += 1
        }
        #expect(momentum.isFinished)
        #expect(momentum.velocity == 0)
        // v0 / -ln(r) per ms: about 999 points for 2000 pt/s at 0.998, minus the cut tail.
        #expect(total > 950 && total < 1000)
        #expect(steps < 400, "stops within a few seconds at 120 Hz")
    }

    @Test func distanceIsIndependentOfFrameRate() {
        var fast = TerminalScrollMomentum(velocity: -1500)
        var slow = TerminalScrollMomentum(velocity: -1500)
        var a = 0.0, b = 0.0
        for _ in 0..<120 { a += fast.step(1.0 / 120) }
        for _ in 0..<60 { b += slow.step(1.0 / 60) }
        #expect(abs(a - b) < 0.5)
        #expect(a < 0)
    }

    @Test func slowOrInvalidStartsFinished() {
        #expect(TerminalScrollMomentum(velocity: 10).isFinished)
        var invalid = TerminalScrollMomentum(velocity: .infinity)
        #expect(invalid.isFinished)
        #expect(invalid.step(0.1) == 0)
    }
}
