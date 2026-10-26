@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Without the feature `controlSocketEarlyBind`, the control socket starts at
/// `LaunchSettle.settled(within:images:)` (cx-z9kz0): after the first terminal frame (at once when the daemon is
/// unavailable) and the launch images, at most 4 s; never at the startup scheduler's 10 s failsafe.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchSettleControlStartTests {
    @Test func anUnavailableDaemonStartsTheControlSocketWithoutWaitingForStartup() async {
        let f = SettleFixture()
        f.scheduler.startup.finishRegistration()
        // `install`'s watch settles the launch when the daemon is unavailable: no frame, no restore.
        f.settle.settle()
        await f.settle.settled(within: .seconds(4), images: f.images)
        #expect(f.scheduler.startup.completion == nil, "the socket did not wait for startup to complete")
    }

    @Test func theControlSocketWaitsForTheLaunchImages() async {
        let f = SettleFixture()
        let share = f.images.began()
        let started = SettleFlag()
        let waiter = Task { @MainActor [settle = f.settle, images = f.images] in
            await settle.settled(within: .seconds(4), images: images)
            started.isSet = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!started.isSet, "the launch has not settled")
        f.settle.settle()
        for _ in 0..<10 { await Task.yield() }
        #expect(!started.isSet, "an agent page still loads behind its last frame")
        share.end(.visiblePaneLoadedIdle)
        await waiter.value
        #expect(started.isSet)
    }

    @Test func aLaunchThatNeverSettlesStartsTheControlSocketAtItsLimit() async throws {
        let f = SettleFixture()
        let waiter = Task { @MainActor [settle = f.settle, images = f.images] in
            await settle.settled(within: .seconds(4), images: images)
        }
        try await f.clock.waitForSleeper()
        f.clock.advance(by: .seconds(4))
        await waiter.value
        #expect(f.scheduler.startup.completion == nil, "4 s, not the startup failsafe")
    }
}

/// A launch settle on a manual clock, with a launch image hold on the shared test scheduler.
@MainActor
private final class SettleFixture {
    let scheduler: StartupTestScheduler
    let images: LaunchImageHold
    let clock: ManualClock
    let settle: LaunchSettle

    init() {
        let scheduler = StartupTestScheduler(), clock = ManualClock()
        images = LaunchImageHold(startup: scheduler.startup)
        settle = LaunchSettle(reveal: LaunchReveal(deadline: .seconds(60)), paneRefs: VisiblePaneRefs(hold: { _ in { _ in } }), clock: clock)
        self.scheduler = scheduler
        self.clock = clock
    }
}

@MainActor
private final class SettleFlag {
    var isSet = false
}
