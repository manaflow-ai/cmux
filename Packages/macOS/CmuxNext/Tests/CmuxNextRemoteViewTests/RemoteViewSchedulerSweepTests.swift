import AppKit
@testable import CmuxNextRemoteView
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import QuartzCore
import Testing

#if DEBUG
/// The desktop pane's status and first frame reach it as visible-class tasks on the app's
/// scheduler, never in an unclassed main-actor hop: a status the source reports is not applied in the stream's
/// delivery, it waits in the visible queue and applies on the frame that runs it; a status of a session the pane
/// stopped (a hidden tab) is dropped. The scheduler's link is kept up and its frames fire only by hand; only the
/// stream's arrival on main is awaited.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteViewSchedulerSweepTests {
    @Test func aStatusAppliesInAVisibleTaskNotInItsDelivery() async throws {
        let rig = SweepRig()
        defer { rig.stop() }
        let source = MockRemoteStreamSource(status: RemoteViewStatus(path: .direct, rttMs: 4, state: .streaming))
        let pane = RemoteDesktopPane(hostName: "mock", source: source, inputSink: nil, mainWork: rig.work, presenter: .layerContents)
        pane.start()
        defer { pane.stop() }
        #expect(pane.state.sessionState == .connecting, "the pane applied a status before its stream delivered one")

        try await rig.untilPosted(.visible)
        #expect(pane.state.sessionState == .connecting, "the status applied in its delivery, not in its visible task")
        #expect(rig.work.postedCount(.automation) == 0 && rig.work.postedCount(.background) == 0)

        rig.runVisibleFrames()
        #expect(pane.state.sessionState == .streaming)
    }

    @Test func aStoppedSessionsLateStatusIsDropped() async throws {
        let rig = SweepRig()
        defer { rig.stop() }
        let source = MockRemoteStreamSource(status: RemoteViewStatus(path: .direct, rttMs: 4, state: .streaming))
        let pane = RemoteDesktopPane(hostName: "mock", source: source, inputSink: nil, mainWork: rig.work, presenter: .layerContents)
        pane.start()
        try await rig.untilPosted(.visible)
        rig.runVisibleFrames()
        #expect(pane.state.sessionState == .streaming)

        // The host ends the session; the pane hides before the ended status's task runs.
        source.setStatus(RemoteViewStatus(path: .direct, rttMs: 4, state: .ended(.connectionLost)))
        try await rig.untilPosted(.visible)
        #expect(!pane.state.isEnded, "the ended status applied in its delivery, not in its visible task")
        pane.stop()
        rig.runVisibleFrames()
        #expect(rig.work.postedCount(.visible) == 0, "the stopped session's status was never run")
        #expect(!pane.state.isEnded, "a hidden pane applied its stopped session's status")
    }
}

/// A scheduler on a fake link kept up (as `ObserverRig` in AutomationObserverTests): a visible post queues until a
/// frame, and frames fire only when the test says, on a budget clock the test moves, with no input pending.
@MainActor
private final class SweepRig {
    let work: MainWorkScheduler
    private let uptime: SweepUptime
    private let keeper: FrameClient
    private var timestamp: CFTimeInterval = 0

    init() {
        _ = NSApplication.shared
        let uptime = SweepUptime()
        self.uptime = uptime
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: uptime.read), clock: ManualClock(),
                                         ledger: WakeupLedger(), performTurn: { _ in }) { _ in SweepLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Waits (bounded) until `workClass` holds a posted task: an off-main post reaches the scheduler on a later main
    /// run loop turn.
    func untilPosted(_ workClass: BudgetedWorkClass) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while work.postedCount(workClass) == 0, ContinuousClock.now < deadline {
            // wakeup-allow: a test's bounded wait for an off-main stream's post to reach main
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(work.postedCount(workClass) > 0, "nothing was posted in \(workClass)")
    }

    /// Fires display frames, one refresh period apart, until the visible queue is empty (at most 8).
    func runVisibleFrames() {
        for _ in 0 ..< 8 where work.postedCount(.visible) > 0 {
            uptime.advance(ms: 17)
            timestamp += 1
            work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        }
    }

    func stop() { keeper.deactivate() }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class SweepUptime {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class SweepLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
#endif
