import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Deferred launch work waits for the agent panes' launch images (cx-z9kz0).
@MainActor
@Suite struct LaunchImageHoldTests {
    @Test func workRunsAtOnceWhenNoImageIsShown() {
        let hold = LaunchImageHold(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        var ran = 0
        hold.whenClear { ran += 1 }
        #expect(ran == 1)
        #expect(!hold.isHolding)
    }

    @Test func workWaitsForTheLastImageThenRunsOnceInOrder() {
        let hold = LaunchImageHold(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        var ran: [String] = []
        hold.began()
        hold.began()
        hold.whenClear { ran.append("palette") }
        hold.whenClear { ran.append("keybinds") }
        hold.ended()
        #expect(ran.isEmpty)
        #expect(hold.isHolding)
        hold.ended()
        #expect(ran == ["palette", "keybinds"])
        hold.ended()
        #expect(ran == ["palette", "keybinds"])
        #expect(!hold.isHolding)
    }

    @Test func anImageThatNeverEndsReleasesTheWorkAtTheBackstop() async throws {
        let clock = ManualClock()
        let hold = LaunchImageHold(backstop: DemandTimer(owner: "test", clock: clock))
        var ran = 0
        hold.began()
        hold.whenClear { ran += 1 }
        try await clock.waitForSleeper()
        clock.advance(by: LaunchImageHold.imageLimit)
        for _ in 0..<20 { await Task.yield() }
        #expect(ran == 0)
        clock.advance(by: .seconds(1))
        for _ in 0..<50 where ran == 0 { await Task.yield() }
        #expect(ran == 1)
    }

    @Test func theLastImageEndingCancelsTheBackstop() async throws {
        let clock = ManualClock()
        let hold = LaunchImageHold(backstop: DemandTimer(owner: "test", clock: clock))
        var ran = 0
        hold.began()
        hold.whenClear { ran += 1 }
        try await clock.waitForSleeper()
        hold.ended()
        #expect(ran == 1)
        clock.advance(by: LaunchImageHold.imageLimit + .seconds(1))
        for _ in 0..<20 { await Task.yield() }
        #expect(ran == 1)
    }

    @Test func clearReturnsOnceTheImageEnds() async {
        let hold = LaunchImageHold(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        hold.began()
        let cleared = Flag()
        let waiter = Task { @MainActor in
            await hold.clear()
            cleared.isSet = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!cleared.isSet)
        hold.ended()
        await waiter.value
        #expect(cleared.isSet)
    }
}

@MainActor
private final class Flag {
    var isSet = false
}
