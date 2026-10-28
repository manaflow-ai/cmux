import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The agent panes' launch images are one startup ref: afterStartup work (the
/// palette's warm-up steps) waits until the last image went (cx-z9kz0), with no timer of its own.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchImageHoldTests {
    @Test func anImageHoldsStartupUntilTheLastOneEnds() {
        let f = HoldFixture()
        let first = f.hold.began()
        let second = f.hold.began()
        f.scheduler.complete()
        #expect(f.startup.heldRefs == ["LaunchImageHold.images"], "two images are one ref")
        first.end(.visiblePaneLoadedIdle)
        f.hand.drain()
        #expect(f.startup.completion == nil, "one image still shows")
        #expect(f.hold.isHolding)
        second.end(.visiblePaneTimedOut)
        f.hand.drain()
        #expect(f.startup.completion?.reason == .visiblePaneTimedOut, "the last image's reason ends startup")
        #expect(!f.hold.isHolding)
    }

    @Test func aReplacedImageNeverEndsTheHoldForATurn() {
        let f = HoldFixture()
        let old = f.hold.began()
        f.scheduler.complete()
        // showLaunchImage: the new image begins before the old one ends.
        let new = f.hold.began()
        old.end(.visiblePaneLoadedIdle)
        f.hand.drain()
        #expect(f.startup.completion == nil)
        #expect(f.startup.heldRefs == ["LaunchImageHold.images"])
        #expect(new.isActive)
    }

    @Test func aShareEndsOnceAndALaterImageHoldsAgain() {
        let f = HoldFixture()
        let first = f.hold.began()
        let second = f.hold.began()
        first.end(.visiblePaneLoadedIdle)
        first.end(.visiblePaneLoadedIdle)
        #expect(!first.isActive)
        #expect(f.hold.isHolding, "a second end of one share never ends another image's")
        second.end(.visiblePaneLoadedIdle)
        #expect(!f.hold.isHolding)
        let later = f.hold.began()
        f.scheduler.complete()
        #expect(f.startup.heldRefs == ["LaunchImageHold.images"])
        later.end(.visiblePaneLoadedIdle)
    }

    @Test func aClosedPanesShareEndsTheHoldBeforeTheFailsafe() {
        let f = HoldFixture()
        let share = f.hold.began()
        f.scheduler.complete()
        #expect(f.startup.heldRefs == ["LaunchImageHold.images"])
        // The pane left its window or was torn down with its image up (PaneContentView).
        share.end(.noVisiblePane)
        f.hand.drain()
        #expect(!f.hold.isHolding)
        #expect(f.startup.completion?.reason == .noVisiblePane, "a closed pane is not a failsafe completion")
        #expect(!f.startup.failsafeArmed, "the failsafe is cancelled")
    }

    @Test func whenClearRunsAtOnceOrWhenTheLastImageEnds() {
        let f = HoldFixture()
        let ran = HoldFlag()
        f.hold.whenClear { ran.isSet = true }
        #expect(ran.isSet, "no image shows")
        ran.isSet = false
        let share = f.hold.began()
        f.hold.whenClear { ran.isSet = true }
        #expect(!ran.isSet)
        share.end(.visiblePaneLoadedIdle)
        #expect(ran.isSet)
    }

    @Test func afterCompletionAnImageHoldsNothing() {
        let f = HoldFixture()
        f.scheduler.complete()
        #expect(f.startup.completion != nil)
        let share = f.hold.began()
        #expect(f.hold.isHolding)
        #expect(f.startup.heldRefs.isEmpty)
        share.end(.visiblePaneLoadedIdle)
    }

    @Test func clearReturnsAtOnceWhenNoImageShowsOrWithNoScheduler() async {
        let f = HoldFixture()
        await f.hold.clear()
        let alone = LaunchImageHold()
        let share = alone.began()
        await alone.clear()
        #expect(alone.isHolding, "a hold with no scheduler holds nothing and waits for nothing")
        share.end(.visiblePaneLoadedIdle)
    }

    @Test func clearReturnsOnceTheLastImageEnds() async {
        let f = HoldFixture()
        let share = f.hold.began()
        let cleared = HoldFlag()
        let waiter = Task { @MainActor [hold = f.hold] in
            await hold.clear()
            cleared.isSet = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!cleared.isSet, "the keybind probes wait for the agent page to paint")
        share.end(.visiblePaneLoadedIdle)
        await waiter.value
        #expect(cleared.isSet)
    }

    @Test func clearReturnsAtTheFailsafeWhenAnImageNeverEnds() async throws {
        let f = HoldFixture()
        let share = f.hold.began()
        f.scheduler.complete()
        let waiter = Task { @MainActor [hold = f.hold] in await hold.clear() }
        try await f.clock.waitForSleeper()
        f.clock.advance(by: StartupScheduler.failsafeTimeout)
        await waiter.value
        #expect(f.startup.completion?.reason == .failsafe, "an image that never ends shows as a failsafe completion")
        share.end(.visiblePaneLoadedIdle)
    }
}

/// A launch image hold on the shared test scheduler.
@MainActor
private final class HoldFixture {
    let scheduler: StartupTestScheduler
    let hold: LaunchImageHold
    var clock: ManualClock { scheduler.clock }
    var hand: StartupTestHop { scheduler.hand }
    var startup: StartupScheduler { scheduler.startup }

    init() {
        let scheduler = StartupTestScheduler()
        self.scheduler = scheduler
        hold = LaunchImageHold(startup: scheduler.startup)
    }
}

@MainActor
private final class HoldFlag {
    var isSet = false
}
