import AppKit
@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// p06-scheduler-331, the sweep of CmuxNextAgentPane's second half, FreeTier and Approvals: one case per migrated
/// owner class (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentPaneSchedulerSweepTests {
    final class Count { var value = 0 }

    @Observable final class Switch { var on = true }

    /// R-hop: the transport's default pacer flushes in one posted `visible` task of the transport's scheduler, never
    /// in the call that scheduled it (an unclassed main-actor Task flushed outside the board before).
    @Test func theNextTurnPacerFlushesInAPostedVisibleTask() {
        let turns = Turns()
        let work = MainWorkScheduler.testing(performTurn: { turns.queue($0) }) { _ in Link() }
        let pacer = AgentPaneNextTurnPacer(mainWork: work)
        let flushes = Count()
        let ran = Ran()
        pacer.schedule {
            flushes.value += 1
            ran.task = work.budget.board.running
            return AgentPaneFlush(delivered: true, more: false)
        }
        pacer.schedule { AgentPaneFlush(delivered: false, more: false) }  // coalesced: one flush is already posted
        #expect(flushes.value == 0, "the pacer flushed in the call")
        #expect(work.postedCount(.visible) == 1)
        turns.runAll()
        #expect(flushes.value == 1)
        #expect(ran.task?.workClass == .visible)
        #expect(ran.task?.owner == "agentPane.transport.nextTurnFlush")
    }

    /// The transport and the shell take the model's scheduler, and the shell's deadlines (a read's wait, Stop's
    /// escalation, the drain after exit) are `visible` deadlines on it: the page waits on each (rule 6).
    @Test func theModelsOwnersShareItsSchedulerAndTheShellsDeadlinesAreVisible() {
        let deadlines = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
        let model = AgentPaneModel(host: MockAgentPaneHost(), deadlines: deadlines)
        #expect(model.transport.mainWork === deadlines.work)
        let run = AgentPaneShell.Run(pid: 0, deadlines: deadlines)
        #expect(run.escalation.workClass == .visible)
        #expect(run.drain.workClass == .visible)
    }

    /// R-obs, ServiceObservation (rule 3): the suggested-tasks switch reaches the next daemon's flag while no page
    /// shows, in one posted task of the scheduler, not on a hidden page's turn.
    @Test func theSuggestedTasksSwitchReachesTheDaemonFlagWithNoPage() {
        let turns = Turns()
        let work = MainWorkScheduler.testing(performTurn: { turns.queue($0) }) { _ in Link() }
        let tasks = AgentPaneSuggestedTasks()
        let setting = Switch()
        tasks.follow(on: work)
        tasks.setting = { setting.on }
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn)
        setting.on = false
        turns.runAll()
        #expect(!AgentPaneSuggestedTasks.forNextDaemon.isOn, "the change did not reach the daemon flag")
        tasks.setting = { true }
    }

    /// R-timer, a race (the Deadline helper): a completion shell that runs past its limit answers `timedOut` at the
    /// limit, and its process group is killed.
    @Test func aCompletionShellPastItsLimitTimesOut() async throws {
        let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.test-complete-timeout", priority: .userBlocking)
        let started = ContinuousClock.now
        await #expect(throws: AgentPaneShellCompletion.Failure.timedOut) {
            _ = try await CompletionProcess.run(path: "/bin/sh", arguments: ["/bin/sh", "-c", "sleep 30"],
                                                environment: ["PATH": "/usr/bin:/bin"], folder: NSTemporaryDirectory(),
                                                timeout: .milliseconds(200), launcher: launcher)
        }
        #expect(ContinuousClock.now - started < .seconds(10), "the limit did not end the wait")
    }

    /// userBlocking (R-hop, PostTaskAndReplyWithResult): the remote-approvals restart runs off main, and its answer
    /// is one userBlocking task of the pane's scheduler, the rest of the person's click.
    @Test func theRemoteApprovalsRestartAnswersInOneUserBlockingTask() {
        let work = MainWorkScheduler.testing { _ in Link() }
        let approvals = AgentPaneRemoteApprovals(machineID: "sweep-machine", label: "sweep-vm", restart: { .keyNotHeld })
        let answer = Answer()
        approvals.restartAnswering(on: work) { failure in
            answer.failure = failure
            answer.task = work.budget.board.running
        }
        #expect(answer.task == nil, "the answer ran in the click's own turn")
        Self.spinMainRunLoop { answer.task != nil }
        #expect(answer.failure == .keyNotHeld)
        #expect(answer.task?.workClass == .userBlocking, "the restart's answer ran outside one userBlocking task")
        #expect(answer.task?.owner == "agentPane.remoteApprovals.restart")
    }

    /// automation (R-hop): the parents a remote daemon listed reach the sidebar's links in one automation task, which
    /// yields to the person's pending input and then runs.
    @Test func theRemoteWiresNoteOfLinksYieldsToPendingInputThenRuns() {
        let rig = PendingInputRig()
        let wire = RemoteAcpmuxWire(start: { _, _ in throw CancellationError() }, mainWork: rig.work)
        let child = "sweep-links-child-\(UUID().uuidString)"
        rig.input.pending = true
        wire.noteLinks([["sessionId": child, "startedBy": "sweep-links-parent"]])
        Self.spinMainRunLoop { rig.work.postedCount(.automation) > 0 }
        #expect(rig.work.postedCount(.automation) == 1, "the note was not one automation task")
        #expect(RemoteAgentSessionLinks.shared.parents[child] == nil, "the note ran ahead of the person's pending input")
        for _ in 0..<2 where RemoteAgentSessionLinks.shared.parents[child] == nil { rig.frame() }
        #expect(RemoteAgentSessionLinks.shared.parents[child] == "sweep-links-parent", "the note waited more than one yield")
        #expect(rig.work.postedCount(.automation) == 0)
    }

    /// background (R-obs, ServiceObservation): the free-tier follow starts the provider with the first inputs, and a
    /// later sign-in change reaches it as one update from one background task.
    @Test func theFreeTierFollowStartsOnTheFirstApplyAndUpdatesOnAChange() async {
        let turns = Turns()
        let work = MainWorkScheduler.testing(performTurn: { turns.queue($0) }) { _ in Link() }
        let signedIn = Switch(), log = StepLog()
        let follow = FreeTierAttestStarter.follow(settings: nil, signedIn: { signedIn.on }, on: work) { step in
            await log.append(step)
        }
        let first = FreeTierAttestStarter.Step.start(FreeTierAttestStarter.Inputs(enabled: true, managed: false, signedIn: true))
        let second = FreeTierAttestStarter.Step.update(FreeTierAttestStarter.Inputs(enabled: true, managed: false, signedIn: false))
        #expect(await log.first(1) == [first], "the first apply did not start the provider")
        signedIn.on = false
        #expect(work.postedCount(.background) == 1, "the change was not one background task")
        turns.runAll()
        #expect(await log.first(2) == [first, second], "the change did not reach the provider as one update")
        withExtendedLifetime(follow) {}
    }

    /// The More menu opens from a run-loop callout, never inside a scheduler task: its tracking loop runs the
    /// scheduler's turns, and a turn run from inside a running drain would re-enter it.
    @Test func theMoreMenuIsNotAScheduledTask() throws {
        let work = MainWorkScheduler.testing(performTurn: { _ in }) { _ in Link() }
        let model = AgentPaneModel(host: MockAgentPaneHost(), deadlines: MainDeadlineScheduler(work: work))
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: model, work: BackgroundWork(label: "test.agent-pane.more"), source: .bundled(file),
                                              webUI: .agentPaneTestHost(), gestures: .testing()))
        defer { view.close() }
        let more: [String: Any] = ["text": "Done.", "forkSeq": 3, "popUp": ["left": 10, "top": 20, "right": 34, "bottom": 44]]
        view.receiveContextMenuReport(more)
        #expect(work.postedCount(.userBlocking) == 0, "the More menu was posted as a scheduler task")
    }

    /// Main run loop passes, where off-main posts (`postFromAnyThread`) arrive, until `done` or 5 s.
    static func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }

    @MainActor final class Ran {
        var task: MainTaskBoard.Task?
    }

    /// The steps the free-tier follow handed on; waits for the first `count` of them.
    actor StepLog {
        private var steps: [FreeTierAttestStarter.Step] = []
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func append(_ step: FreeTierAttestStarter.Step) {
            steps.append(step)
            let ready = waiters.filter { $0.count <= steps.count }
            waiters.removeAll { $0.count <= steps.count }
            for waiter in ready { waiter.continuation.resume() }
        }

        func first(_ count: Int) async -> [FreeTierAttestStarter.Step] {
            if steps.count < count {
                await withCheckedContinuation { waiters.append((count, $0)) }
            }
            return Array(steps.prefix(count))
        }
    }

    @MainActor final class Answer {
        var failure: AgentPaneRemoteApprovals.Failure?
        var task: MainTaskBoard.Task?
    }

    /// A scheduler on a fake link with a clock the test moves and an input source it sets; frames fire by hand.
    @MainActor final class PendingInputRig {
        let input: Input
        let clock: HandClock
        let work: MainWorkScheduler
        private let keeper: FrameClient
        private var timestamp: Double = 0

        init() {
            let input = Input(), clock = HandClock()
            self.input = input
            self.clock = clock
            work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: { clock.now })) { _ in Link() }
            keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
            keeper.activate()
        }

        /// One display frame, a frame period after the last.
        func frame() {
            clock.now += 17_000_000
            timestamp += 1
            work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        }

        @MainActor final class HandClock {
            var now: UInt64 = 1_000_000_000
        }

        @MainActor final class Input: InputPendingSource {
            var pending = false
            func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
        }
    }

    /// The scheduler's posted turns, run by hand.
    @MainActor final class Turns {
        private var pending: [@MainActor () -> Void] = []

        func queue(_ turn: @escaping @MainActor () -> Void) { pending.append(turn) }

        func runAll() {
            while !pending.isEmpty { pending.removeFirst()() }
        }
    }

    @MainActor final class Link: FrameLink {
        var isPaused = false
        func invalidate() {}
    }
}
