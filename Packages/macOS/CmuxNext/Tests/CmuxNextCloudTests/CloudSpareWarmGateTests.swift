@testable import CmuxNextCloud
import Foundation
import Testing

/// hq#8747 ask 4: the app warms the spare on every activation, and each warm spawned a CLI process
/// before Rust's throttle answered. A burst of activations now starts one warm.
@MainActor @Suite struct CloudSpareWarmGateTests {
    final class Clock { var now = ContinuousClock.now }

    @Test func aBurstOfActivationsStartsOneWarm() {
        let clock = Clock()
        let gate = CloudSpareWarmGate(now: { clock.now })
        var spawned = 0
        for _ in 0..<100 {
            if gate.admit("person") { spawned += 1 }
            clock.now += .milliseconds(50)
        }
        print("CloudSpareWarmGateTests: 100 activations in 5 s: \(spawned) warm process(es) (before: 100)")
        #expect(spawned == 1)
        #expect(gate.skipped == 99)
    }

    @Test func aWarmRunsAgainAfterTheGapAndForAnotherPerson() {
        let clock = Clock()
        let gate = CloudSpareWarmGate(now: { clock.now })
        #expect(gate.admit("person"))
        #expect(gate.admit("teammate"), "another account's warm is its own")
        clock.now += CloudSpareWarmGate.gap
        #expect(!gate.admit("person"), "still running: the first warm has not ended")
        gate.ended("person")
        #expect(gate.admit("person"))
        gate.ended("person")
        clock.now += .seconds(1)
        #expect(!gate.admit("person"), "within the gap of the last start")
    }
}
