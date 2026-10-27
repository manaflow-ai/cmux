import AppKit
@testable import CmuxNextRemoteView
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import QuartzCore
import Testing

#if DEBUG
/// p06-scheduler-345: the desktop pane's status and first frame reach it as visible-class tasks on the app's
/// scheduler, never in an unclassed main-actor hop: a status the source reports is not applied in the stream's
/// delivery, it waits in the visible queue and applies in the turn that runs it; a status of a session the pane
/// stopped (a hidden tab) is dropped. Turns run by hand; only the stream's arrival on main is awaited.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteViewSchedulerSweepTests {
    @Test func aStatusAppliesInAVisibleTaskNotInItsDelivery() async throws {
        let rig = SweepRig()
        let source = MockRemoteStreamSource(status: RemoteViewStatus(path: .direct, rttMs: 4, state: .streaming))
        let pane = RemoteDesktopPane(hostName: "mock", source: source, inputSink: nil, mainWork: rig.work, presenter: .layerContents)
        pane.start()
        defer { pane.stop() }
        #expect(pane.state.sessionState == .connecting, "the pane applied a status before its stream delivered one")

        try await rig.untilPosted(.visible)
        #expect(pane.state.sessionState == .connecting, "the status applied in its delivery, not in its visible task")
        #expect(rig.work.postedCount(.automation) == 0 && rig.work.postedCount(.background) == 0)

        rig.runTurns()
        #expect(pane.state.sessionState == .streaming)
    }

    @Test func aStoppedSessionsLateStatusIsDropped() async throws {
        let rig = SweepRig()
        let source = MockRemoteStreamSource(status: RemoteViewStatus(path: .direct, rttMs: 4, state: .streaming))
        let pane = RemoteDesktopPane(hostName: "mock", source: source, inputSink: nil, mainWork: rig.work, presenter: .layerContents)
        pane.start()
        try await rig.untilPosted(.visible)
        rig.runTurns()
        #expect(pane.state.sessionState == .streaming)

        // The host ends the session; the pane hides before the ended status's task runs.
        source.setStatus(RemoteViewStatus(path: .direct, rttMs: 4, state: .ended(.connectionLost)))
        try await rig.untilPosted(.visible)
        pane.stop()
        rig.runTurns()
        #expect(!pane.state.isEnded, "a hidden pane applied its stopped session's status")
    }
}

/// A scheduler with no running link: each post queues one run loop turn here, and the test runs them.
@MainActor
private final class SweepRig {
    private var turns: [@MainActor () -> Void] = []
    let work: MainWorkScheduler

    init() {
        _ = NSApplication.shared
        var perform: MainWorkScheduler.TurnPerformer = { _ in }
        work = MainWorkScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), performTurn: { perform($0) }) { _ in SweepLink() }
        perform = { [weak self] turn in self?.turns.append(turn) }
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

    /// Runs the queued turns, and the turns they queue, until none is left.
    func runTurns() {
        while !turns.isEmpty {
            let now = turns
            turns.removeAll()
            for turn in now { turn() }
        }
    }
}

@MainActor
private final class SweepLink: FrameLink {
    var isPaused = false
    func invalidate() {}
    func requestFrameRate(_ range: CAFrameRateRange) {}
}
#endif
