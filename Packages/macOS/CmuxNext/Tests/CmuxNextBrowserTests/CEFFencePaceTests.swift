import AppKit
@testable import CmuxNextBrowser
import Testing

/// The adaptive in-tree resize fence pace (`CMUX_NEXT_CEF_FENCE_PACE=adaptive`, ``CEFFencePace``): a window whose pages
/// kept up with its last 8 fences waits longer for the next page frame, one whose pages missed 3 of them waits for none
/// for 120 ms, then probes at the fixed wait again. The clock is the test's.
@MainActor
@Suite struct CEFFencePaceTests {
    final class Clock {
        var now: TimeInterval = 100
    }

    let clock = Clock()
    let window = ObjectIdentifier(NSObject.self)

    func pace() -> CEFFencePace {
        let clock = clock
        return CEFFencePace(now: { clock.now })
    }

    @Test func aFreshWindowWaitsTheFixedWait() {
        let pace = pace()
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == 4)
        #expect(pace.wait(window: window, base: 9, refreshMs: 8.33, windowResized: true) == 9)
    }

    @Test func pagesThatKeptUpWithEightFencesGetAWholeFrame() {
        let pace = pace()
        for _ in 0..<7 { pace.record(window: window, presented: true) }
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == 4, "7 kept up is not 8")
        pace.record(window: window, presented: true)
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == 8)
        #expect(pace.wait(window: window, base: 9, refreshMs: 8.33, windowResized: true) == 12)
        // One miss in the last 8: back to the fixed wait.
        pace.record(window: window, presented: false)
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == 4)
    }

    @Test func threeMissesWaitForNoPageFor120MsThenProbe() {
        let pace = pace()
        pace.record(window: window, presented: false)
        pace.record(window: window, presented: true)
        pace.record(window: window, presented: false)
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == 4)
        pace.record(window: window, presented: false)
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == nil, "fell behind, still waited")
        clock.now += 0.119
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == nil)
        clock.now += 0.002
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == 4, "no probe after the pause")
        #expect(pace.histories[window]?.outcomes.isEmpty == true, "the probe judged old outcomes")
    }

    @Test func eachWindowKeepsItsOwnPace() {
        let pace = pace()
        let other = ObjectIdentifier(NSView.self)
        for _ in 0..<3 { pace.record(window: other, presented: false) }
        #expect(pace.wait(window: other, base: 4, refreshMs: 8.33, windowResized: false) == nil)
        #expect(pace.wait(window: window, base: 4, refreshMs: 8.33, windowResized: false) == 4)
    }

    @Test func theLongWaitIsNeverShorterThanTheFixedOne() {
        #expect(CEFFencePace.longMs(base: 17, refreshMs: 8.33, windowResized: false) == 17)
        #expect(CEFFencePace.longMs(base: 8, refreshMs: 16.67, windowResized: false) == 16)
        #expect(CEFFencePace.longMs(base: 17, refreshMs: 16.67, windowResized: true) == 25)
    }
}
