import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The agent panes' launch images are one startup ref (p08-startup-016): afterStartup work (the
/// palette's warm-up steps) waits until the last image went (cx-z9kz0), with no timer of its own.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchImageHoldTests {
    @Test func anImageHoldsStartupUntilTheLastOneEnds() {
        let f = HoldFixture()
        f.hold.began()
        f.hold.began()
        f.completeImplicitRefs()
        #expect(f.startup.heldRefs == ["LaunchImageHold.images"], "two images are one ref")
        f.hold.ended()
        f.hand.drain()
        #expect(f.startup.completion == nil, "one image still shows")
        #expect(f.hold.isHolding)
        f.hold.ended(.visiblePaneTimedOut)
        f.hand.drain()
        #expect(f.startup.completion?.reason == .visiblePaneTimedOut, "the last image's reason ends startup")
        #expect(!f.hold.isHolding)
    }

    @Test func aReplacedImageNeverEndsTheHoldForATurn() {
        let f = HoldFixture()
        f.hold.began()
        f.completeImplicitRefs()
        // showLaunchImage: the new image begins before the old one ends.
        f.hold.began()
        f.hold.ended()
        f.hand.drain()
        #expect(f.startup.completion == nil)
        #expect(f.startup.heldRefs == ["LaunchImageHold.images"])
    }

    @Test func extraEndsDoNothingAndALaterImageHoldsAgain() {
        let f = HoldFixture()
        f.hold.ended()
        f.hold.began()
        f.hold.ended()
        f.hold.ended()
        #expect(!f.hold.isHolding)
        f.hold.began()
        f.completeImplicitRefs()
        #expect(f.startup.heldRefs == ["LaunchImageHold.images"], "a count never goes below zero")
    }

    @Test func afterCompletionAnImageHoldsNothing() {
        let f = HoldFixture()
        f.completeImplicitRefs()
        #expect(f.startup.completion != nil)
        f.hold.began()
        #expect(f.hold.isHolding)
        #expect(f.startup.heldRefs.isEmpty)
        f.hold.ended()
    }

    @Test func clearReturnsAtOnceWhenNoImageShowsOrWithNoScheduler() async {
        let f = HoldFixture()
        await f.hold.clear()
        let alone = LaunchImageHold()
        alone.began()
        await alone.clear()
        #expect(alone.isHolding, "a hold with no scheduler holds nothing and waits for nothing")
    }

    @Test func clearReturnsOnceTheLastImageEnds() async {
        let f = HoldFixture()
        f.hold.began()
        let cleared = HoldFlag()
        let waiter = Task { @MainActor [hold = f.hold] in
            await hold.clear()
            cleared.isSet = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!cleared.isSet, "the keybind probes wait for the agent page to paint")
        f.hold.ended()
        await waiter.value
        #expect(cleared.isSet)
    }

    @Test func clearReturnsAtTheFailsafeWhenAnImageNeverEnds() async throws {
        let f = HoldFixture()
        f.hold.began()
        f.completeImplicitRefs()
        let waiter = Task { @MainActor [hold = f.hold] in await hold.clear() }
        try await f.clock.waitForSleeper()
        f.clock.advance(by: StartupScheduler.failsafeTimeout)
        await waiter.value
        #expect(f.startup.completion?.reason == .failsafe, "a lost image shows as a failsafe completion")
    }
}

/// A launch image hold on a test scheduler.
@MainActor
private final class HoldFixture {
    let scheduler = LaunchTestScheduler()
    let hold: LaunchImageHold
    var clock: ManualClock { scheduler.clock }
    var hand: LaunchTestHop { scheduler.hand }
    var startup: StartupScheduler { scheduler.startup }

    init() {
        hold = LaunchImageHold(startup: scheduler.startup)
    }

    func completeImplicitRefs() { scheduler.completeImplicitRefs() }
}

@MainActor
private final class HoldFlag {
    var isSet = false
}
