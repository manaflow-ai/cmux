import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Observation
import Testing

/// The launch settle (first live terminal frame, or no daemon) and the cleanup that waits for it.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchSettleTests {
    @MainActor @Observable
    final class Daemon {
        var isUnavailable = false
    }

    private let reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60))
    private let hold = LaunchImageHold(backstop: DemandTimer(owner: "test", clock: ManualClock()))

    @Test func workWaitsForTheSettleThenRunsOnceInOrderAfterTheAppStep() {
        var ran: [String] = []
        let settle = LaunchSettle(reveal: reveal, imageHold: hold, onSettle: { ran.append("app") })
        settle.whenSettled { ran.append("palette") }
        settle.whenSettled { ran.append("icon picker") }
        #expect(ran.isEmpty)
        settle.settle()
        settle.settle()
        #expect(ran == ["app", "palette", "icon picker"])
        settle.whenSettled { ran.append("late") }
        #expect(ran == ["app", "palette", "icon picker", "late"])
    }

    @Test func settledWorkWaitsForTheLaunchImages() {
        var ran = 0
        let settle = LaunchSettle(reveal: reveal, imageHold: hold)
        settle.whenSettled { ran += 1 }
        hold.began()
        settle.settle()
        #expect(ran == 0)
        hold.ended()
        #expect(ran == 1)
    }

    @Test func theFirstTerminalFrameShowsThePaneAndSettles() {
        let settle = LaunchSettle(reveal: reveal, imageHold: hold)
        settle.install(isUnavailable: { false })
        settle.firstTerminalFrame()
        #expect(reveal.isReady(.pane))
        #expect(settle.isSettled)
    }

    @Test func thePaneShownAnyOtherWaySettles() {
        let settle = LaunchSettle(reveal: reveal, imageHold: hold)
        settle.install(isUnavailable: { false })
        #expect(!settle.isSettled)
        reveal.markReady(.pane)
        #expect(settle.isSettled)
    }

    @Test func anUnavailableDaemonShowsEverythingAndSettles() async {
        let daemon = Daemon()
        let settle = LaunchSettle(reveal: reveal, imageHold: hold)
        settle.install(isUnavailable: { [daemon] in daemon.isUnavailable })
        #expect(!settle.isSettled)
        daemon.isUnavailable = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in settle.whenSettled { done.resume() } }
        #expect(reveal.isRevealed)
    }

    @Test func theCleanupRunsOnceAtTheSettle() {
        var cleanups = 0
        let settle = LaunchSettle(reveal: reveal, imageHold: hold)
        LaunchCleanup(cleanUpDownloadTempFiles: { cleanups += 1 }).schedule(on: settle)
        #expect(cleanups == 0)
        settle.settle()
        settle.settle()
        #expect(cleanups == 1)
    }
}
