import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Deferred launch work waits for the agent panes' launch images (cx-z9kz0).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchImageHoldTests {
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
        hold.began()
        let released = Flag()
        // One waiter only: each whenClear resets the backstop.
        let waiter = Task { @MainActor in
            await hold.clear()
            released.isSet = true
        }
        try await clock.waitForSleeper()
        clock.advance(by: LaunchImageHold.imageLimit)
        #expect(clock.sleeperCount == 1)
        #expect(!released.isSet)
        clock.advance(by: .seconds(1))
        await waiter.value
        #expect(released.isSet)
        #expect(clock.sleeperCount == 0)
    }

    @Test func theLastImageEndingCancelsTheBackstop() {
        let backstop = DemandTimer(owner: "test", clock: ManualClock())
        let hold = LaunchImageHold(backstop: backstop)
        var ran = 0
        hold.began()
        hold.whenClear { ran += 1 }
        #expect(backstop.isScheduled)
        hold.ended()
        #expect(ran == 1)
        #expect(!backstop.isScheduled)
    }

    @Test func clearReturnsOnceTheImageEnds() async throws {
        let clock = ManualClock()
        let hold = LaunchImageHold(backstop: DemandTimer(owner: "test", clock: clock))
        hold.began()
        let cleared = Flag()
        let waiter = Task { @MainActor in
            await hold.clear()
            cleared.isSet = true
        }
        // clear() has registered once its backstop sleeps.
        try await clock.waitForSleeper()
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
